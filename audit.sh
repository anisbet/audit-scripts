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
declare -a EXTENSIONS=('*.js' '*.sh' '*.py' '*.pl' 'Makefile')
## Database
APP_TABLE="App"
SERVER_TABLE="Server"
DEPEND_TABLE="Dependent"
SCHED_TABLE="Schedule"
PROJECT_TABLE="Project" # Form: project/name|file.sh
HOSTNAME=$(hostname | pipe.pl -W'\.' -oc0)
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
    crontab -l | pipe.pl -Gc0:'#|SHELL' | pipe.pl -W'\s+' -gc5:'^\.$' -oc0,c1,c2,c3,c4,c6 -i | pipe.pl -oc0,c1,c2,c3,c4,c5 | pipe.pl -W'\/' -oc0,last | pipe.pl -oc5,exclude -mc6:"$HOSTNAME\|#" | pipe.pl -oc6,c5,remaining >$SCHED_TABLE
}

# Collect all the names of all scripts on this machine. The function ignores 
# .git, .svn, .npm and other hidden files and directories
# param:  none
find_scripts()
{
    # Start with a fresh list.
    echo "" >$FILE_LIST
    ## now loop through the above array
    for i in "${EXTENSIONS[@]}"
    do
       echo "searching for extension: '$i'"
       # During find ignore hidden files and directories. This avoids .npm and .git directories.
       find $HOME -not -path "*/\.*" -name "$i" >> $FILE_LIST
    done
}

# The project table includes the names of all sibling, and daughter scripts that
# are physically grouped in a directory, and sub-directories. A strong feature
# of a project is the namespace the script's directory, and its parent directory.
# For example a file located in /home/user/a/b/foo.sh is well described as project 
# 'a/b'. This identifies the difference between c/a foo.sh and a/b foo.sh.
# between .
compile_project_table()
{
    if [ ! -s "$FILE_LIST" ]; then
        echo "no scripts found in $HOME with the following extensions: " >&2
        for i in "${EXTENSIONS[@]}"
        do
            echo "search included '$i'"
        done
        exit 1
    fi
    # This is simply a many-to-one relationship that lists the project name -> app.
    # Example:
    # /home/ilsdev|three.js
    # ilsdev1|monkey-mat.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|estj-bone-2-anim.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|monkey-anim.js|three.js/essential-threejs/assets/models/exported
    perl -n -e 'use File::Basename; print(dirname($_)."|".basename($_));' audit.apps.path.lst | sed 's,'"${HOME}"'/,'"${HOSTNAME}"'|,g' | pipe.pl -oc0,c2,c1 > $PROJECT_TABLE
}

# Compile the listed files into the 'Dependent' table. Requires $FILE_LIST to run.
# param:  none
# return: none
compile_dependent_table()
{
    if [ ! -s "$FILE_LIST" ]; then
        echo "no scripts found in $HOME with the following extensions: " >&2
        for i in "${EXTENSIONS[@]}"
        do
            echo "search included '$i'"
        done
        exit 1
    fi
    # Read the $FILE_LIST line by line and analyse for references to other scripts.
    echo >/tmp/audit.depend.lst
    while IFS= read -r line; do
        if echo "$line" | egrep -i "*.js$" >/dev/null 2>/dev/null; then
            echo "skipping js file"
        elif echo "$line" | egrep -i "Makefile$" >/dev/null 2>/dev/null; then
            echo "skipping Makefile file because they reference their targets necessarily"
        else
            echo "["`date +'%Y-%m-%d %H:%M:%S'`"] analysing $line"
            local file_name=$(echo "$line" | perl -ne 'use File::Basename; print(basename($_));' -)
            env HOST="$HOSTNAME|$file_name|$line" perl -n -e 'while(m/(?=.*\W)\w{2,}\.(pl|sh|py|js)\s/g){ chomp($script=$&);print("$ENV{HOST}|$script\n"); }' "$line" >>/tmp/audit.depend.lst
        fi
    done < "$FILE_LIST"
    # Clean the Dependent table of duplicates, and files that reference themselves.
    cat /tmp/audit.depend.lst | pipe.pl -oc0,c1,c3,c2 | pipe.pl -Bc1,c2 | pipe.pl -dc0,c1,c2 >$DEPEND_TABLE
}


############################# Functions #################################


# Loop through the file list and pull out relevant info in pipe-delimited files appending as we go.
while getopts ":Acx" opt; do
  case $opt in
    A)  echo "-A to audit and create all tables." >&2
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SERVER_TABLE." >&2
        audit_cron
        find_scripts
        compile_project_table
        compile_dependent_table
        ;;
    c)	echo "-c to audit the crontab only." >&2 
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SERVER_TABLE." >&2
        audit_cron
        ;;
    x)	usage
        ;;
    \?)	echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
  esac
done
exit 0
# EOF
