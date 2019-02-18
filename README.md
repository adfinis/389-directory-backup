# 389-directory-backup
The 389-directory-backup provides a [389 Directory
Server](https://directory.fedoraproject.org/) backup script and systemd
service, to periodically create backups while the 389 Directory Server is
online. It is mainly a wrapper script around the
[`db2bak.pl`](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/perl_scripts#Perl_Scripts-db2bak.pl_Create_backup_of_database)([source](https://pagure.io/389-ds-base/blob/master/f/ldap/admin/src/scripts/db2bak.pl.in)).

## Overview
TODO

## Usage
TODO

## Installation
TODO

## Links
* [Red Hat Directory Server 10 - Administration Guide - Backing up and Restoring Data](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/administration_guide/populating_directory_databases-backing_up_and_restoring_data)
* [`db2bak.pl`](https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/perl_scripts#Perl_Scripts-db2bak.pl_Create_backup_of_database)

## License
This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, version 3 of the License.

## Copyright
Copyright (c) 2019 [Adfinis SyGroup AG](https://adfinis-sygroup.ch)
