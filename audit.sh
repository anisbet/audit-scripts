#!/bin/bash
##############################################################################
#
# Performs audit of services and their relationships.
#
# Copyright (c) Andrew Nisbet 2020
#
# For the purposes of an audit we want to automate mapping of scripts and their
# environments which are made up of the following features.
# * The servers on which it is stored, and where it is deployed.
# * Non-standard inputs and functional dependencies.
# * What it produces.
# * How the script is run, for example run by schedule, or on demand, or by
#   other scripts.
#
# Assumptions: script targets have file extensions of *.py, *.sh, *.pl, *.js.
# These are the important automation that was developed in house.
# Inputs are identified by searching for other references as those already
# listed, but also by cross checks with scripts with non-standard names found
# in Bin or especially Bincustom.
# Keywords include: 'source', ' . ', 'import', 'require', '>', '>>', 
# 'open', 'ssh', as well as common binary names like 'mailx' offer clues.# 
#
##############################################################################
FILE_LIST=audit.apps.path.lst
HOME=~
DBASE=./audit.db # Not implemented yet.
TRUE=0
FALSE=1
# These are the types of files we will be specificaly targetting. The nature
# of these tests doesn't allow the search and exploration of binary files.
declare -a EXTENSIONS=('*.js' '*.sh' '*.py' '*.pl')
## Database
DEPEND_TABLE="Dependent.lst"    # Dependencies for scripts.
SCHED_TABLE="Schedule.lst"  # Actively scheduled scripts.
PROJECT_TABLE="Project.lst" # Relates sibling scripts together.
CONNECT_TABLE="Connect.lst" # The other servers the script may interact with.
LOCATION_TABLE="Location.lst" # Where the file is located on a given server's file system.
HOSTNAME=$(hostname | pipe.pl -W'\.' -oc0) # just the conventional name of the server.
VERSION=0.1
############################# Functions #################################
# Display usage message.
# param:  none
# return: none
usage()
{
    cat << EOFU!
Usage: $0 [-option]
 Audits scripts for facets that explain their relationship to other systems.

 By default this script creates a database called $DBASE that can be useful for
 further analysis, but the final goal is to automate and if possible, illustrate
 the relationships of home brew software that interact with the ILS.

 Switches:
 -A: Perform all tasks required in an audit. Includes searching for all the scripts
     analysing them for dependencies, schedule, logging their projects, 
     creating a database called $DBASE.
 -c: Checks the cron for actively scheduled scripts and reports.
 
 Version: $VERSION
EOFU!
    exit 3
}

# Asks if user would like to do what the message says.
# param:  message string.
# return: 0 if the answer was yes and 1 otherwise.
confirm()
{
	if [ -z "$1" ]; then
		echo "** error, confirm_yes requires a message." >&2
		exit $FALSE
	fi
	local message="$1"
	echo "$message? y/[n]: " >&2
	read answer
	case "$answer" in
		[yY])
			echo "yes selected." >&2
			echo $TRUE
			;;
		*)
			echo "no selected." >&2
			echo $FALSE
			;;
	esac
}

# Audit the cron table and output the contents to the schedule table.
# Example output:
# load_cma_stats.sh|ilsdev1|45|23|*|*|*
# load_discards.sh|ilsdev1|30|08|*|*|1,2,3,4,5
# statdb.pl|ilsdev1|30|21|*|*|*
# param:  none.
# return: none.
audit_cron()
{
    # script | host | minute | hour | day | month | DOW
    crontab -l | pipe.pl -Gc0:'#|SHELL' | pipe.pl -W'\s+' -gc5:'^\.$' -oc0,c1,c2,c3,c4,c6 -i | pipe.pl -oc0,c1,c2,c3,c4,c5 | pipe.pl -W'\/' -oc0,last | pipe.pl -oc5,exclude -mc6:"$HOSTNAME\|#" | pipe.pl -oc5,c6,remaining >$SCHED_TABLE
}

# Compile the listed files into the 'Dependent' table. Requires $FILE_LIST to run.
# param:  none
# return: none
compile_tables()
{
    # This is simply a many-to-one relationship that lists the project name -> app.
    # Example:
    # /home/ilsdev|three.js
    # ilsdev1|monkey-mat.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|estj-bone-2-anim.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|monkey-anim.js|three.js/essential-threejs/assets/models/exported
    perl -n -e 'use File::Basename; print(dirname($_)."|".basename($_));' "$FILE_LIST" | sed 's,'"${HOME}"'/,'"${HOSTNAME}"'|,g' | pipe.pl -oc0,c2,c1 | pipe.pl -zc1 > $PROJECT_TABLE
    # Read the $FILE_LIST line by line and analyse for references to other scripts.
    echo >/tmp/audit.depend.lst
    echo >/tmp/audit.connect.lst
    echo >/tmp/audit.location.lst
    while IFS= read -r file_path; do
        if echo "$file_path" | egrep -i "*.js$" >/dev/null 2>/dev/null; then
            echo "skipping $file_path"
        else
            local file_name=$(echo "$file_path" | perl -ne 'use File::Basename; print(basename($_));' -)
            # Add the file to the location table
            echo "$HOSTNAME|$file_name|$file_path" >>/tmp/audit.location.lst
            echo -n "["`date +'%Y-%m-%d %H:%M:%S'`"] analysing $file_name"
            cat "$file_path" | sed -e '/^[ \t]*#/d' | env HOST="$HOSTNAME|$file_name" perl -n -e 'while(m/(?=.*\W)\w{2,}\.(pl|sh|py|js)\s/g){ chomp($script=$&);print("$ENV{HOST}|$script\n"); }' - >>/tmp/audit.depend.lst
            echo -n ", dependencies: done"
            # Collect any information about whether this script talks with other servers. The markers are
            # 'ssh', 'mysql', 'sftp', 'HTTP', 'scp', IPs and hostnames.
            #  (\w+((\.\w+)+)?\@\w+((\.\w+)+)?)|((?=\s?)(mysql|ssh|scp|sftp)\s)|(http:\/\/\w+((\.\w+)+)?)|(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})
            cat "$file_path" | sed -e '/^[ \t]*#/d' | env HOST="$HOSTNAME|$file_name" perl -n -e 'while(m/(\w+((\.\w+)+)?\@\w+((\.\w+)+)?)|((?=\s?)(mysql|ssh|scp|sftp)\s)|(http:\/\/\w+((\.\w+)+)?)|(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/gi){ chomp($server=$&);$server=q/localhost/ if (! $server);print("$ENV{HOST}|$server\n"); }' - >>/tmp/audit.connect.lst
            echo ", connections: done"
        fi
    done < "$FILE_LIST"
    # Clean the Dependent table of duplicates, and files that reference themselves.
    cat /tmp/audit.depend.lst | pipe.pl -Bc1,c2 -zc1 | pipe.pl -dc0,c1,c2 >$DEPEND_TABLE
    cat /tmp/audit.connect.lst | pipe.pl -Bc1,c2 -zc1 | pipe.pl -dc0,c1,c2 >$CONNECT_TABLE
    cat /tmp/audit.location.lst | pipe.pl -zc1 >$LOCATION_TABLE
}

# Collect all the names of all scripts on this machine. The function ignores 
# .git, .svn, .npm and other hidden files and directories
# param:  none
audit_scripts()
{
    # Start with a fresh list.
    echo >$FILE_LIST
    ## now loop through the above array
    for i in "${EXTENSIONS[@]}"
    do
       echo "searching for extension: '$i'"
       # During find ignore hidden files and directories. This avoids .npm and .git directories.
       find $HOME -not -path "*/\.*" -name "$i" >> $FILE_LIST
    done
    if [ ! -s "$FILE_LIST" ]; then
        echo "no scripts found in $HOME with the following extensions: " >&2
        for i in "${EXTENSIONS[@]}"
        do
            echo "search included '$i'"
        done
        exit 1
    fi
    # Carry on with compilation of table data as lists.
    compile_tables
}
############################# Functions #################################


# Loop through the file list and pull out relevant info in pipe-delimited files appending as we go.
while getopts ":Acx" opt; do
  case $opt in
    A)  echo "-A to audit and create all tables." >&2
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SCHED_TABLE." >&2
        audit_cron
        audit_scripts
        ;;
    c)	echo "-c to audit the crontab only." >&2 
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SCHED_TABLE." >&2
        audit_cron
        ;;
    x)	usage
        ;;
    \?)	usage
        ;;
    *)	echo "** Invalid option: -$OPTARG" >&2
        usage
        ;;
  esac
done
exit 0
# EOF
