#!/bin/bash
# Script to use Schema Registry API to back up and restore SUBJECTS and schemas for DC switchover.  
## Use this INSTEAD of manually backup/restoring _schemas using kafka-console-consumer/producer.
# The topic to be synced (such as _schemas) is defined in the schema-registry server
#  inside /etc/schema-registry/schema-registry.properties by what's served on port 8081.


# Set your configuration vars
SOURCE_SCHEMA_REGISTRY_URL="http://DC1-cdp-01:8081" # Replace with your source DC Schema Registry URL
DESTINATION_SCHEMA_REGISTRY_URL="http://DC2-cdp-01:8081" # Replace with your destination DC Schema Registry URL
BACKUP_DIR="schemas_backup_$(date +%Y%m%d_%H%M%S)" # Unique backup directory


echo "--- Starting Schema Registry API-driven Backup/Restore for Datacenter Switchover ---"

# --- Part 1: Backup from Source Datacenter ---
echo "1. BACKING UP Source DC Schema Registry Subjects."
echo " Stop applications now that register new schemas in Source Datacenter (manual step)"
echo "   This is to ensure no new schemas are registered during the backup process."
echo "   Please ensure Schema Registry is gracefully shut down in the source DC AFTER this script runs the backup."
echo "   Press Enter to continue..."
read

echo "2. Backing up schemas from source Schema Registry: $SOURCE_SCHEMA_REGISTRY_URL"
mkdir -p "$BACKUP_DIR"

# Get all subjects
SUBJECTS=$(curl -s "$SOURCE_SCHEMA_REGISTRY_URL/subjects" | jq -r '.[]')

if [ -z "$SUBJECTS" ]; then
    echo "No subjects found in source Schema Registry. Exiting."
    exit 1
fi

for SUBJECT in $SUBJECTS; do
    echo "  - Backing up subject: $SUBJECT"
    # Get all versions for the subject
    VERSIONS=$(curl -s "$SOURCE_SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions" | jq -r '.[]')

    for VERSION in $VERSIONS; do
        echo "    - Backing up version: $VERSION"
        # Get the schema for each version and save it
        curl -s "$SOURCE_SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions/$VERSION" > "$BACKUP_DIR/${SUBJECT}_${VERSION}.json"
    done

    # Also backup compatibility level for the subject (if applicable)
    COMPATIBILITY=$(curl -s "$SOURCE_SCHEMA_REGISTRY_URL/config/$SUBJECT" | jq -r '.compatibilityLevel')
    if [ "$COMPATIBILITY" != "null" ]; then
        echo "    - Backing up compatibility for $SUBJECT: $COMPATIBILITY"
        echo "{\"compatibilityLevel\": \"$COMPATIBILITY\"}" > "$BACKUP_DIR/${SUBJECT}_compatibility.json"
    fi
done

echo "Schema backup complete! Data saved to: $BACKUP_DIR"
echo "Now, you can safely stop Schema Registry in the Source Datacenter."
echo "Press Enter to continue after stopping Schema Registry in source DC..."
read

# --- Part 2: Restore to Destination Datacenter ---
echo "3. RESTORE to Destination Datacenter."
echo "   Ensure Schema Registry is started in the destination DC and connected to the new Kafka cluster."
echo "   It should be running with the _schemas(_prod_schemas) topic reset/empty and leader.eligibility=true."
echo "   Press Enter to continue after starting Schema Registry..."
read

echo "4. Restoring schemas to destination Schema Registry: $DESTINATION_SCHEMA_REGISTRY_URL"

# Restore schemas by subject and version
for SCHEMA_FILE in "$BACKUP_DIR"/*_*.json; do
    if [[ "$SCHEMA_FILE" == *"_compatibility.json" ]]; then
        # Handle compatibility configurations separately
        SUBJECT=$(basename "$SCHEMA_FILE" _compatibility.json)
        echo "  - Restoring compatibility for subject: $SUBJECT"
        curl -X PUT -H "Content-Type: application/vnd.schemaregistry.v1+json" \
             --data @"$SCHEMA_FILE" \
             "$DESTINATION_SCHEMA_REGISTRY_URL/config/$SUBJECT"
    else
        # Handle schema versions
        FILENAME=$(basename "$SCHEMA_FILE" .json)
        SUBJECT=$(echo "$FILENAME" | sed -E 's/_[0-9]+$//') # Extract subject by removing _version_number
        
        # Schema Registry only needs the schema definition, not the whole response object from backup
        SCHEMA_CONTENT=$(jq '.schema' "$SCHEMA_FILE") # Extract just the "schema" string
        
        echo "  - Restoring schema for subject: $SUBJECT from $SCHEMA_FILE"
        # The POST endpoint for /subjects/{subject}/versions will auto-assign a new version
        # It's better to let Schema Registry manage the version assignment on restore.
        curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
             --data "{\"schema\": $SCHEMA_CONTENT}" \
             "$DESTINATION_SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions"
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to restore schema for $SUBJECT from $SCHEMA_FILE. Check Schema Registry logs."
        fi
    fi
done

echo "Schema restore complete!"

# --- Part 3: Final Verification ---
echo "5. Verifying restored subjects (optional)"
curl -s "$DESTINATION_SCHEMA_REGISTRY_URL/subjects" | jq .

echo "--- Schema Registry API-driven Backup/Restore Complete ---"

# --- Part 3: Count and compare subjects between datacenters ------------------------#
echo "Count and compare subjects between datacenters"

# Function to get the subject count from a Schema Registry URL
get_subject_count() {
    local url=$1
    local count
    
    # Use curl to get the list of subjects and jq to get the array length
    count=$(curl --silent -X GET "${url}/subjects" | jq '. | length')
    
    # Check if jq returned a valid number. A non-number indicates an error.
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not retrieve subject count from ${url}" >&2
        return 1
    fi
    echo "${count}"
}

echo "Retrieving subject counts..."

# Get the subject count for the first Schema Registry
count1=$(get_subject_count "${SOURCE_SCHEMA_REGISTRY_URL}")
if [ $? -ne 0 ]; then
    exit 1
fi

# Get the subject count for the second Schema Registry
count2=$(get_subject_count "${DESTINATION_SCHEMA_REGISTRY_URL}")
if [ $? -ne 0 ]; then
    exit 1
fi

echo "Schema Registry 1 (${SOURCE_SCHEMA_REGISTRY_URL}) has ${count1} subjects."
echo "Schema Registry 2 (${DESTINATION_SCHEMA_REGISTRY_URL}) has ${count2} subjects."

# Compare the counts
if [[ "${count1}" -eq "${count2}" ]]; then
    echo "Result: The total number of subjects is the same."
elif [[ "${count1}" -gt "${count2}" ]]; then
    echo "Result: Source Schema Registry has more subjects than Destination Schema Registry."
else
    echo "Result: Destination Schema Registry has more subjects than Source Schema Registry."
fi

exit 0
