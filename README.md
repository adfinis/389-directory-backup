# 389-directory-backup
The 389-directory-backup provides a [389 Directory
Server](https://directory.fedoraproject.org/) backup script and systemd
service, to periodically create backups while the 389 Directory Server is
running.

## Overview
The [`389-directory-backup.sh`](bin/389-directory-backup.sh) script creates
data and configuration backups from a locally running 389 Directory Server. It
uses the Directory Server backup task
[`cn=backup,cn=tasks,cn=config`](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/core_server_configuration_reference#cn-backup)
to create database backups.

In a first step, the script creates a new backup task entry
(`cn=389-directory-backup-<TIMESTAMP>)` to backup all the available databases
into a corresponding directory below a given root backup directory (by default
to `/var/lib/dirsrv/slapd-<INSTANCE>/bak/dirsrv-backup-<TIMESTAMP>`). The
script then polls the [task's
status](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/core_server_configuration_reference#cn-tasks-attributes)
until the task  has finished or timed-out. It also copies the current
[dse.ldif](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/administration_guide/populating_directory_databases-backing_up_and_restoring_data#Backing_Up_and_Restoring_Data-Backing_Up_the_dse.ldif_Configuration_File)
(server configuration) into the backup directory.  After a successful backup
run, the script optionally purges old backup directories.

It is intended to be run on a daily basis and includes the necessary systemd
service and timer units for running it on Systemd enabled systems. The root
backup directory should be included within the local backup process.

### What about `db2bak.pl`?
Although the existing
[`db2bak.pl`](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/perl_scripts#Perl_Scripts-db2bak.pl_Create_backup_of_database)
script already provides a similar functionality, it doesn't support polling and
thus one would need to manually check if the backup task was successful or not.
Apart from that, it is marked as
['deprecated'](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/perl_scripts#Perl_Scripts-db2bak.pl_Create_backup_of_database)
and will be removed in the next major version, according to Red Hat.

## Usage
After the [installation of the script](#installation), the script can either be
invoked manually to create an ad-hoc backup or periodically via the
[Systemd](#systemd-usage).

By default the script uses the `cn=Directory Manager` to bind to the directory
server on localhost. It expects the corresponding bind password within
`/etc/389-directory-backup.passwd` (or whatever was set as the `sysconfdir`
during the installation).
Make sure, that the password file doesn't contain any trailing newline (`\n`)
and that restrictive permissions are in place for this file.

The backups will be stored below `/var/lib/dirsrv/slapd-<INSTANCE>/bak` whereas
`<INSTANCE>` reflects the 389 Directory Server instance name
(`/etc/dirsrv/slapd-<INSTANCE>`) which can be specified via `-i <INSTANCE>` and
defaults to the hostname of the system running this script.

### Script usage
```bash
389-directory-backup.sh -h
```
```
Usage: 389-directory-backup.sh [-b BACKUPDIR] [-D LDAPBINDDN] [-H LDAPURI]
                               [-i INSTANCE ] [-k DAYS] [-p PASSWDFILE]
                               [-t SECONDS] [-rdhv]

    -b BACKUPDIR    The directory to store the backup, defaults to
                    '/var/lib/dirsrv/slapd-example/bak'
    -d              Enable debug messages
    -D LDAPBINDDN   The LDAP bind DN to use, defaults to
                    'cn=Directory Manager'
    -H LDAPURI      The LDAP URI of the LDAP server, defaults to
                    'ldap://localhost:389'
    -i INSTANCE     The 389 directory server instance to backup, defaults to
                    the name of this host ('localhost')
    -k DAYS         Days to keep old backups, if backup removal has been
                    enabled (see -r), defaults to '7'
    -p PASSWDFILE   The LDAP passwd file to use, defaults to
                    '/etc/389-directory-backup.passwd'
    -r              Enable backup removal (deletion of old backups),
                    disabled by default.
    -t SECONDS      The timeout in seconds for the backup task to complete,
                    defaults to '3600'
    -h              Display this help and exit
    -v              Display the version and exit

Note, that all options are also overridable via environment variables.

The bind password is expected within the PASSWDFILE (-p). Reading the bind
password from a file, rather than passing it via an input option, prevents the
password from being exposed to other processes or users.
```

### Script usage example
The following example creates a backup for the `ldap-01` instance:
```bash
# Write the "cn=Directory Manager" password to the LDAP passwd file
touch /etc/389-directory-backup.passwd
chown root:dirsrv /etc/389-directory-backup.passwd
chmod 640 /etc/389-directory-backup.passwd
echo -n "changeme" > /etc/389-directory-backup.passwd

# Initiate a backup as the dirsrv user
su -c '389-directory-backup.sh -i "ldap-01"' -s /bin/bash dirsrv
``` 

The backup should be available at the following location:
```
/var/lib/dirsrv/slapd-ldap-01/bak/dirsrv-backup-YYYY-MM-DDTHH:MM:SSZ
```

### Systemd usage
The 389 directory backup can be run under Systemd with the corresponding
[Systemd service and timer template unit](systemd/).

It supports multiple 389 directory server instances, which must correspond with
the Systemd instance. The LDAP bind password file is expected within
`/etc/389-directory-backup-<INSTANCE>.passwd` (or whatever was set as the
`sysconfdir` during the installation).

The service environment file is located at `/etc/389-directory-backup-env.conf`
which acts as the default for all instances. The service unit also tries to
load a `/etc/389-directory-backup-<INSTANCE>-env.conf` envirnoment file, which
can be used to optionally override stettings on a per instance basis.


The following example configures a Systemd service and timer unit instance for a
corresponding 389 directory server instance named `ldap-01`:
```bash
# Set the instance name to your corresponding 389 directory server instance
instanceName="ldap-01"

# Make sure that this 389 directory server instance is active
systemctl status "dirsrv@${instanceName}.service"

# Write the "cn=Directory Manager" password to the LDAP passwd file
ldapPasswdFile="/etc/389-directory-backup-${instanceName}.passwd"
touch "${ldapPasswdFile}"
chown root:dirsrv "${ldapPasswdFile}"
chmod 640 "${ldapPasswdFile}"
echo -n "changeme" > "${ldapPasswdFile}"


# Start the 389 backup service unit
systemctl start "389-directory-backup@${instanceName}.service"

# Make sure the backup has completed succcessfully
systemctl status "389-directory-backup@${instanceName}.service"
journalctl -u "389-directory-backup@${instanceName}.service"

# Enable and start the corresponding timer unit
systemctl enable "389-directory-backup@${instanceName}.timer"
systemctl start "389-directory-backup@${instanceName}.timer"
```

### Restore
To restore the database or the `dse.ldif` follow the excellent [Restoring
Databases from the Command
Line](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/administration_guide/populating_directory_databases-backing_up_and_restoring_data#Restoring_All_Databases-Restoring_Your_Database_from_the_Command_Line)
chapter of the Red Hat directory server administration guide.

## Installation
To install the script and the corresponding Systemd service units proceed with
the following steps:

1. Install, configure an start your 389 directory server
2. Clone this repository 
3. Use the provided Makefile to install

```bash
# Clone the repository either via SSH or HTTPS
git clone https://github.com/adfinis-sygroup/389-directory-backup.git
git clone git@github.com:adfinis-sygroup/389-directory-backup.git

# Change to the repository root directory
cd 389-directory-backup

# Install the script and corresponding files 
#
# The Makefile installs with a prefix set to /usr/local by default and supports
# common directory variables to change the locations.
# 
# Let's install to /usr/local except for the configuration files, which should
# go to /etc
make sysconfdir=/etc install
```

You can now proceed with the [usage](#usage) section.

## Links
* [Red Hat Directory Server 10 - Administration Guide - Backing up and Restoring Data](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/administration_guide/populating_directory_databases-backing_up_and_restoring_data)

## License
This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, version 3 of the License.

## Copyright
Copyright (c) 2019 [Adfinis SyGroup AG](https://adfinis-sygroup.ch)
