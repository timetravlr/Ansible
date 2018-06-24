Ansible playbook examples. 
Started 2016 - M.Sallee  - 
Goals: we needed to have a way to automate basic Linux configuration files across multiple systems, and to join Linux to Active Directory.

Linux_playbooks: contains CentOS6 example of joining Linux to Active Directory.  
Example usage: (requires ssh keys to be configured)
ansible-playbook main.yml

Mac_playbooks: contains Mac OSX 10.13 tested example of joining to Active Directory.
Example usage: enter your credentials in the script, then:
ansible-playbook domainjoin-mac.yml
