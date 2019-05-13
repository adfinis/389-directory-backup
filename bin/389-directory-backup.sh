#!/bin/bash
################################################################################
# 389-directory-backup.sh - Creates backups of a 389 directory server
################################################################################
#
# Copyright (C) 2019 Adfinis SyGroup AG
#                    https://adfinis-sygroup.ch
#                    info@adfinis-sygroup.ch
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU Affero General Public
# License as published  by the Free Software Foundation, version
# 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License  along with this program.
# If not, see <http://www.gnu.org/licenses/>.
#
# Please submit enhancements, bugfixes or comments via:
# https://github.com/adfinis-sygroup/389-directory-backup
#
# Authors:
#  Christian Affolter <christian.affolter@adfinis-sygroup.ch>
#
# Description:
# This script creates data and configuration backups from a running 389
# Directory Server. It uses the Directory Server backup task
# (cn=backup,cn=tasks,cn=config) to create database backups.
#
# It creates a backup task to backup all the available databases into a
# timestamped directory below a given root backup directory. The script then
# polls the task's status until it has finished or timed-out. It also copies
# the current dse.ldif (server configuration) into the backup directory.  After
# a successful backup run, the script optionally purges old backup directories.
# It is intended to be run on a daily basis, the root backup directory should
# be included within the local backup process.
#
# It returns 0 on success or a non-zero exit status on failures.
#
# See also:
# * https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/administration_guide/populating_directory_databases-backing_up_and_restoring_data#backup-cn-tasks
# * https://github.com/adfinis-sygroup/389-directory-backup
#
# Usage:
# ./389-directory-backup.sh
#
# See 389-directory-backup.sh -h for further options
#

# Enable pipefail:
# The return value of a pipeline is the value of the last (rightmost) command
# to exit with a non-zero status, or zero if all commands in the pipeline exit
# successfully.
set -o pipefail

# Check if all required external commands are available
for cmd in awk \
           base64 \
           cp \
           date \
           dirname \
           find \
           hostname \
           ldapadd \
           ldapsearch \
           mkdir \
           realpath \
           rm
do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo >&2 "Missing command '${cmd}'"
        exit 1
    }

done


###
# Common settings
#
# The directory path to this script
scriptDir="$(dirname $(realpath "$0"))"

# The path to the configuration directory
confDir="$(realpath "${scriptDir}/../etc")"

# The short host name (without the domain suffix)
hostName="$(hostname --short)"


###
# 389 Directory Server related settings
#
# The 389 Directory Server instance name
dirServInstanceNameDefault="${hostName}"
dirServInstanceName="${DIRECTORY_BACKUP_DIRSRV_INSTANCE_NAME:-${dirServInstanceNameDefault}}"

# The 389 Directory Server configuration directory
dirServConfigDirDefault="/etc/dirsrv"
dirServConfigDir="${DIRECTORY_BACKUP_DIRSRV_CONFIG_DIR:-${dirServConfigDirDefault}}"

# The 389 Directory Server data directory
dirServDataDirDefault="/var/lib/dirsrv"
dirServDataDir="${DIRECTORY_BACKUP_DIRSRV_DATA_DIR:-${dirServDataDirDefault}}"


###
# LDAP related settings
#
# The URI of the LDAP server
# Overridable via input argument or LDAPURI env according to LDAP.CONF(5)
ldapUriDefault="ldap://localhost:389"
ldapUri="${LDAPURI:-${ldapUriDefault}}"

# The LDAP bind DN to use
# Overridable via input argument or LDAPBINDDN env according to LDAP.CONF(5)
ldapBindDefault="cn=Directory Manager"
ldapBind="${LDAPBINDDN:-${ldapBindDefault}}"

# The LDAP passwd file to use
# This file contains the bind password for simple authentication
ldapPasswdFileDefault="${confDir}/389-directory-backup.passwd"
ldapPasswdFile="${DIRECTORY_BACKUP_LDAP_PASSWDFILE:-${ldapPasswdFileDefault}}"

# The LDAP backup task date (note, that the date shorthand of --iso-8601=seconds
# can't be used, as this would result in a timezone designator which includes a
# colon than can't be used without escaping in an LDAP DN)
ldapBackupTaskDate="$(date --utc +%FT%TZ)"

# The LDAP backup task RDN
ldapBackupTaskCn="389-directory-backup-${ldapBackupTaskDate}"

# The LDAP backup task base DN
ldapBackupTaskDn="cn=${ldapBackupTaskCn},cn=backup,cn=tasks,cn=config"

# The LDAP backup task entry time to live in seconds
# Keep the entry for one week by default to allow debugging in case of errors
ldapTaskDefaultTtl="$(( 86400 * 7 ))"
ldapTaskTtl="${DIRECTORY_BACKUP_TASK_TTL:-${ldapTaskDefaultTtl}}"

# The LDAP backup task attributes
ldapArchivDirAttribute="nsArchiveDir"
ldapDatabaseTypeAttribute="nsDatabaseType"
ldapTaskExitCodeAttribute="nsTaskExitCode"
ldapTaskLogAttribute="nsTaskLog"
ldapTaskStatusAttribute="nsTaskStatus"
ldapTaskTtlAttribute="ttl"

# The LDAP CLI debug options (empty by default)
ldapDebugOpt=""

# The LDAP network timeout (in seconds)
# Overridable via LDAPNETWORK_TIMEOUT env according to LDAP.CONF(5)
export LDAPNETWORK_TIMEOUT="${LDAPNETWORK_TIMEOUT:-"3"}"

# Timeout (in seconds) after which calls to LDAP APIs will abort if no response
# is received.
# Overridable via LDAPTIMEOUT env according to LDAP.CONF(5)
export LDAPTIMEOUT="${LDAPTIMEOUT:-"5"}"

# Checks to perform on server certificates in a TLS session
# Overridable via LDAPTLS_REQCERT env according to LDAP.CONF(5)
export LDAPTLS_REQCERT="${LDAPTLS_REQCERT:-"demand"}"


###
# Backup behaviour related settings
#
# Timeout in seconds for the backup task to complete (one hour by default)
backupTaskTimeoutDefault="3600"
backupTaskTimeout="${DIRECTORY_BACKUP_TASK_TIMEOUT:-${backupTaskTimeoutDefault}}"

# Enable backup removal (clean-up old backups)
backupRemovalDefault="disabled"
backupRemoval="${DIRECTORY_BACKUP_REMOVAL:-${backupRemovalDefault}}"

# Days to keep old backups
backupDaysToKeepDefault=7
backupDaysToKeep="${DIRECTORY_BACKUP_DAYS_TO_KEEP:-${backupDaysToKeepDefault}}"


##
# Private variables, do not overwrite them
#
# Script Version
_VERSION="0.1.0"

# Backup task LDIF output cache
_backupTaskLdifCache=""


##
# Helper functions
#

# Prints a debug message
#
# debugMsg MESSAGE
function debugMsg ()
{
    if [ "$DEBUG" = "yes" ]; then
        echo "[DEBUG] $1"
    fi
}


# Prints an info message
#
# infoMsg MESSAGE
function infoMsg ()
{
    echo "[INFO] $1"
}


# Prints an error message
#
# errorMsg MESSAGE
function errorMsg ()
{
    echo "[ERROR] $1" >&2
}


# Prints an error message and exists immediately with an non-zero exit code
#
# dieMsg MESSAGE
function dieMsg ()
{
    echo "[DIE] $1" >&2
    exit ${2:-1}
}

# Process all arguments passed to this script
#
# processArguments
function processArguments ()
{
    # Define all options as unset by default
    declare -A optionFlags

    for optionName in b d D h H i k p r t v; do
        optionFlags[${optionName}]=false
    done

    # Set default action
    action="Backup"

    while getopts ":b:D:H:i:k:p:t:rdhv" option; do
        debugMsg "Processing option '${option}'"

        case "$option" in
            b )
                # The backup root directory
                backupRootDir="${OPTARG}"
                debugMsg "backupRootDir set to: '${backupRootDir}'"
            ;;

            D )
                # The Bind DN to be used
                ldapBind="${OPTARG}"
                debugMsg "ldapBind set to: '${ldapBind}'"
            ;;

            H )
                # The LDAP URI of the LDAP server
                ldapUri="${OPTARG}"
                debugMsg "ldapUri set to: '${ldapUri}'"
            ;;

            i )
                # The 389 Directory Server instance name
                dirServInstanceName="${OPTARG}"
                debugMsg "dirServInstanceName set to: '${dirServInstanceName}'"
            ;;

            k )
                # Days to keep old backup if backup removal has been enabled
                backupDaysToKeep="${OPTARG}"
                debugMsg "backupDaysToKeep set to: '${backupDaysToKeep}'"
            ;;

            p )
                # The LDAP passwd file to use
                ldapPasswdFile="${OPTARG}"
                debugMsg "ldapPasswdFile set to: '${ldapPasswdFile}'"
            ;;

            r )
                # Enable backup removal (deletion of old backups)
                backupRemoval="enabled"
            ;;

            t )
                # The timeout in seconds for the backup task to complete
                backupTaskTimeout="${OPTARG}"
                debugMsg "backupTaskTimeout set to: '${backupTaskTimeout}'"
            ;;

            d )
                # Enable debug messages
                export DEBUG="yes"
                debugMsg "Enabling debug messages"
            ;;

            h )
                action="PrintUsage"
            ;;

            v )
                action="PrintVersion"
            ;;

            \? )
                errorMsg "Invalid option '-${OPTARG}' specified"
                action="PrintUsageWithError"
            ;;

            : )
                errorMsg "Missing argument for '-${OPTARG}'"
                action="PrintUsageWithError"
            ;;
        esac

        optionFlags[${option}]=true # Option was provided
    done


    if ! [[ "${dirServInstanceName}" =~ ^([[:alnum:]]|[_\-])+$ ]]; then
        dieMsg "Invalid 389 directory server instance name specified"
    fi

    # The 389 directory instance configuration directory
    dirServInstanceConfigDir="${dirServConfigDir}/slapd-${dirServInstanceName}"

    # The 389 directory instance backup directory
    dirServInstanceBackupDir="${dirServDataDir}/slapd-${dirServInstanceName}/bak"

    # The backup root directory, defaults to the 389 directory instance "bak"
    # dir.
    backupRootDir="${backupRootDir:-${DIRECTORY_BACKUP_ROOT_DIR:-"${dirServInstanceBackupDir}"}}"


    # Allow the usage section and version to be displayed even if the
    # environment isn't sane later on.
    [ "${action}" = "PrintUsage" ] || [ "${action}" = "PrintVersion" ] && \
        return 0

    test -d "${dirServConfigDir}" || \
        dieMsg "Non-existent dirsrv config dir '${dirServConfigDir}'"

    test -d "${dirServInstanceConfigDir}" || \
        dieMsg "Non-existent dirsrv instance config dir '${dirServInstanceConfigDir}'"

    test -r "${dirServInstanceConfigDir}" || \
        dieMsg "No read permissions on instance config dir '${backupRootDir}'"


    test -d "${dirServDataDir}" || \
        dieMsg "Non-existent backup data dir '${dirServDataDir}'"

    test -d "${backupRootDir}" || \
        dieMsg "Non-existent backup root dir '${backupRootDir}'"

    test -w "${backupRootDir}" || \
        dieMsg "No write permissions on backup root dir '${backupRootDir}'"


    # Cheap LDAP URI validation
    if ! [[ "${ldapUri}" =~ ^ldap(s|i)?://([[:alnum:]]|[[:punct:]])+$ ]]; then
        dieMsg "Invalid LDAP URI specified"
    fi

    # Cheap bind DN validation
    if ! [[ "${ldapBind}" =~ ^[[:alnum:]]+=[[:print:]]+$ ]]; then
        dieMsg "Invalid LDAP bind DN specified"
    fi

    test -r "${ldapPasswdFile}" || \
        dieMsg "Non-existent or unreadable LDAP passwd file '${ldapPasswdFile}'"

    if ! [[ "${ldapTaskTtl}" =~ ^[1-9]+[0-9]*$ ]]; then
        dieMsg "LDAP task TTL must be a positive integer"
    fi

    if ! [[ "${backupTaskTimeout}" =~ ^[1-9]+[0-9]*$ ]]; then
        dieMsg "Backup timeout must be a positive integer"
    fi

    if [ "${backupRemoval}" != "enabled" ] && \
       [ "${backupRemoval}" != "disabled" ]
    then
        dieMsg "Backup removal must be set to 'enabled' or 'disabled'"
    fi

    if ! [[ "${backupDaysToKeep}" =~ ^[1-9]+[0-9]*$ ]]; then
        dieMsg "Days to keep old backups must be a positive integer"
    fi

    # Can be increased to "-d -1 -vvv"
    [ "$DEBUG" = "yes" ] && ldapDebugOpt="-v"

    debugMsg "Action:              ${action}"
    debugMsg "dirServInstanceName: ${dirServInstanceName}"
    debugMsg "dirServConfigDir:    ${dirServConfigDir}"
    debugMsg "dirServDataDir:      ${dirServDataDir}"
    debugMsg "backupRootDir:       ${backupRootDir}"
    debugMsg "ldapUri:             ${ldapUri}"
    debugMsg "ldapBind:            ${ldapBind}"
    debugMsg "ldapPasswdFile:      ${ldapPasswdFile}"
    debugMsg "ldapTaskTtl:         ${ldapTaskTtl}"
    debugMsg "ldapDebugOpt:        ${ldapDebugOpt}"
    debugMsg "backupTaskTimeout:   ${backupTaskTimeout}"
    debugMsg "backupRemoval:       ${backupRemoval}"
    debugMsg "backupDaysToKeep:    ${backupDaysToKeep}"

}

# Displays the help message
#
# actionPrintUsage
function actionPrintUsage ()
{
    cat << EOF

Usage: $( basename "$0" ) [-b BACKUPDIR] [-D LDAPBINDDN] [-H LDAPURI]
                               [-i INSTANCE ] [-k DAYS] [-p PASSWDFILE]
                               [-t SECONDS] [-rdhv]

    -b BACKUPDIR    The directory to store the backup, defaults to
                    '${dirServInstanceBackupDir}'
    -d              Enable debug messages
    -D LDAPBINDDN   The LDAP bind DN to use, defaults to
                    '${ldapBindDefault}'
    -H LDAPURI      The LDAP URI of the LDAP server, defaults to
                    '${ldapUriDefault}'
    -i INSTANCE     The 389 directory server instance to backup, defaults to
                    the name of this host ('${dirServInstanceNameDefault}')
    -k DAYS         Days to keep old backups, if backup removal has been
                    enabled (see -r), defaults to '${backupDaysToKeepDefault}'
    -p PASSWDFILE   The LDAP passwd file to use, defaults to
                    '${ldapPasswdFileDefault}'
    -r              Enable backup removal (deletion of old backups),
                    ${backupRemovalDefault} by default.
    -t SECONDS      The timeout in seconds for the backup task to complete,
                    defaults to '${backupTaskTimeoutDefault}'
    -h              Display this help and exit
    -v              Display the version and exit

Note, that all options are also overridable via environment variables.

The bind password is expected within the PASSWDFILE (-p). Reading the bind
password from a file, rather than passing it via an input option, prevents the
password from being exposed to other processes or users.
EOF
}

# Displays the help message and exit with error
#
# actionPrintUsage
function actionPrintUsageWithError ()
{
    actionPrintUsage
    exit 1
}

# Displays the version of this script
#
# actionPrintVersion
function actionPrintVersion ()
{
    cat << EOF
Copyright (C) 2019 Adfinis SyGroup AG

$( basename "$0" ) ${_VERSION}

License AGPLv3: GNU Affero General Public License version 3
                https://www.gnu.org/licenses/agpl-3.0.html
EOF
}


# Performs the 389 directory backup
#
# actionBackup
function actionBackup ()
{
    infoMsg "Starting 389 directory backup"

    # Create the actual backup directory
    # Note, that the ${backupDbDir} will be created by the dirsrv backup task
    # itself.
    local backupDirPrefix="dirsrv-backup-"
    local backupDir="${backupRootDir}/${backupDirPrefix}${ldapBackupTaskDate}"
    local backupDbDir="${backupDir}/db"
    local backupDseDir="${backupDir}/dse"

    mkdir --mode=700 "${backupDir}" || \
        dieMsg "Unable to create backup directory '${backupDir}'"

    mkdir --mode=700 "${backupDseDir}" || \
        dieMsg "Unable to create backup dse directory '${backupDseDir}'"

    # Create the backup task within the directory
    createBackupTask "${backupDbDir}" || \
        dieMsg "Unable to create LDAP backup task entry"

    # Wait for backup task to complete
    waitForBackupTask || dieMsg "Waiting for backup task failed"

    # Check for backup task exit code
    local taskExitCode=0
    local returnCode=0
    taskExitCode="$( getBackupTaskValue "${ldapTaskExitCodeAttribute}" )"
    returnCode="$?"

    debugMsg "getBackupTaskValue returnCode:   '${returnCode}'"
    debugMsg "getBackupTaskValue taskExitCode: '${taskExitCode}'"

    # LDAP exit code check
    test "${returnCode}" -eq 0 || dieMsg "Unable to get task exit code from LDAP"

    local taskStatus="$( getBackupTaskValue "${ldapTaskStatusAttribute}" )"

    if [ "${taskExitCode}" -ne 0 ]; then
        local taskLogValue="$( getBackupTaskValue "${ldapTaskLogAttribute}" )"
        local taskLogEntry="$( base64 --decode <<< "${taskLogValue}" )"
        errorMsg "Unsuccessful backup task run, exit code ${taskExitCode}"
        errorMsg "Task status: ${taskStatus}"
        errorMsg "Task log: ${taskLogEntry}"
        errorMsg "Check ${ldapBackupTaskDn}"
        dieMsg "Backup was not successful"
    fi

    infoMsg "Backup task was successful (${taskStatus})"

    infoMsg "Copying current dse LDIFs to backup dse directory"
    cp -p "${dirServInstanceConfigDir}/dse.ldif"* "${backupDseDir}/." || \
        dieMsg "Unable to copy dse LDIFs to '${backupDseDir}'"


    # Backup clean-up
    if [ "${backupRemoval}" = "enabled" ]; then
        infoMsg "Removing backup older than ${backupDaysToKeep} day(s)"
        find "${backupRootDir}" \
             -maxdepth 1 \
             -type d \
             -name "${backupDirPrefix}*" \
             -mtime "+${backupDaysToKeep}" \
             -exec rm -rf {} \; || \
            dieMsg "Unable to remove old backups"
    fi

    infoMsg "389 directory backup was successful"
    infoMsg "Backup is available at: ${backupDir}"
    return 0
}


# Creates the 389 directory backup task
#
# Adds the backup task entry and returns the return code of ldapadd
# See also:
# https://access.redhat.com/documentation/en-us/red_hat_directory_server/10/html/configuration_command_and_file_reference/core_server_configuration_reference#cn-backup
#
# createBackupTask BACKUPDIR
function createBackupTask ()
{
    local backupDir="${1}"

    ldapadd ${ldapDebugOpt} \
            -D "${ldapBind}" \
            -H "${ldapUri}" \
            -y "${ldapPasswdFile}" \
            -x << EO_LDIF
dn: ${ldapBackupTaskDn}
objectclass: extensibleObject
cn: ${ldapBackupTaskCn}
${ldapArchivDirAttribute}: ${backupDir}
${ldapDatabaseTypeAttribute}: ldbm database
${ldapTaskTtlAttribute}: ${ldapTaskTtl}
EO_LDIF

    return $?
}


# Wait for backup task to finish
#
# Waits for the backup task to finish or time out
# Returns 0 if the task has finished, 1 if an LDAP error occurred, 2 if the
# task has timed out.
#
# waitForBackupTask
function waitForBackupTask ()
{
    # The timeout timestamp in seconds since the epoche
    local timeoutTimestamp="$(( $( date +%s ) + ${backupTaskTimeout} ))"

    local stdout=""
    # Poll the backup task until the "${ldapTaskExitCodeAttribute}" exists or
    # an LDAP search error or timeout occurred.
    until test -n "${stdout}"; do
        if [ $( date +%s ) -ge ${timeoutTimestamp} ]; then
            errorMsg "Backup task timeout occurred after ${backupTaskTimeout} seconds"
            return 2
        fi

        debugMsg "Wait for ${ldapTaskExitCodeAttribute} existence..."

        stdout="$( ldapsearch ${ldapDebugOpt} \
                              -A \
                              -LLL \
                              -b "${ldapBackupTaskDn}" \
                              -s "base" \
                              -x \
                              -D "${ldapBind}" \
                              -y "${ldapPasswdFile}" \
                              -H "${ldapUri}" \
                              "(${ldapTaskExitCodeAttribute}=*)" \
                              "${ldapTaskExitCodeAttribute}" )"

        if [ $? -ne 0 ]; then
            errorMsg "LDAP search error occurred $?"
            return 1
        fi

        debugMsg "Result from ldapsearch: '${stdout}'"

        # Prevent hammering the 389 directory
        debugMsg "Sleeping for 5 seconds until the next task poll..."
        sleep 5
    done

    return 0
}


# Get the backup task LDIF
#
# Prints the "${ldapBackupTaskDn}" LDIF output
# Returns the exit status from ldapsearch
#
# getBackupTaskLdif
function getBackupTaskLdif ()
{
    debugMsg "Get '${ldapBackupTaskDn}' LDIF"
    ldapsearch ${ldapDebugOpt} \
	      -LLL \
	      -b "${ldapBackupTaskDn}" \
	      -s "base" \
	      -x \
	      -D "${ldapBind}" \
	      -y "${ldapPasswdFile}" \
	      -H "${ldapUri}" \
              -o ldif-wrap=no \
              "cn" "${ldapArchivDirAttribute}" "${ldapDatabaseTypeAttribute}" \
              "${ldapTaskExitCodeAttribute}" "${ldapTaskLogAttribute}" \
              "${ldapTaskStatusAttribute}" "${ldapTaskTtlAttribute}"

    return $?
}


# Get the backup task value
#
# Prints a the value of a given LDAP task entry attribute
# Uses a cached getBackupTaskLdif LDIF output
# Returns the exit status from the last exit code
#
# getBackupTaskValue LDAPATTRIBUTE
function getBackupTaskValue ()
{
    local attribute="$1"

    if test -z "${_backupTaskLdifCache}"; then
        _backupTaskLdifCache="$(getBackupTaskLdif)"
        test $? -eq 0 || return 1
    fi

    awk --field-separator ': ' \
        --source "/^${attribute}:/ { print \$2 }" <<< "${_backupTaskLdifCache}"

    return $?
}

# The main function of this script
#
# Processes the passed command line options and arguments,
# checks the environment and calls the action.
#
# main $@
main() {
    processArguments "$@"

    # Uppercase the first letter of the action name and call the function
    action${action^}

    exit $?
}


# Calling the main function and passing all parameters to it
main "$@"
