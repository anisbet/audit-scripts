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
DEPEND="Dependent"
SCHED="Schedule"
PROJECT="Project"
CONNECT="Connect"
LOCATION="Location"
## flat file names.
DEPEND_LIST="$DEPEND.lst"  # Dependencies for scripts.
SCHED_LIST="$SCHED.lst"    # Actively scheduled scripts.
PROJECT_LIST="$PROJECT.lst"   # Relates sibling scripts together.
CONNECT_LIST="$CONNECT.lst"   # The other servers the script may interact with.
LOCATION_LIST="$LOCATION.lst" # Where the file is located on a given server's file system.
declare -a OUTPUT_FILES=("$FILE_LIST" "$DEPEND_LIST" "$SCHED_LIST" "$PROJECT_LIST" "$CONNECT_LIST" "$LOCATION_LIST")
HOSTNAME=$(hostname | pipe.pl -W'\.' -oc0) # just the conventional name of the server.
VERSION=1.3
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
 -a: Audit scripts and create flat files only. This is used for just auditing a 
     machine, then using the results on a different machine, say where the database
     is, or will be created. This flag creates a tarball for the purposes of moving
     the files, then deletes all of its' list files.
 -A: Perform all tasks required in an audit. Includes searching for all the scripts
     analysing them for dependencies, schedule, logging their projects, 
     creating a database called $DBASE. This flag creates a tarball for the purposes of moving
     the files, then deletes all of its' list files.
 -c: Checks the cron for actively scheduled scripts and reports.
 -d: Build the database and load the data.
 -R: Rebuilds the database. Removes the $DBASE and recreates it, then unpacks all
     the audit tarballs in the current directory and reloads the data, and cleans up.
 -s: Show the database schema. If the database doesn't exist you will be prompted 
     to build it. If *.sql files exist in the directory, they will be laoded
     otherwise an empty database is created, and the schema output to STDOUT.
 -x: Displays this usage message.
 
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
	echo -n "$message? y/[n]: " >&2
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
audit_cron()
{
    # script | host | minute | hour | day | month | DOW
    crontab -l | pipe.pl -Gc0:'#|SHELL' | pipe.pl -W'\s+' -gc5:'^\.$' -oc0,c1,c2,c3,c4,c6 -i | pipe.pl -oc0,c1,c2,c3,c4,c5 | pipe.pl -W'\/' -oc0,last | pipe.pl -oc5,exclude -mc6:"$HOSTNAME\|#" | pipe.pl -oc5,c6,remaining >$SCHED_LIST
}

# Compile the listed files into the 'Dependent' table. Requires $FILE_LIST to run.
# param:  none
compile_tables()
{
    # This is simply a many-to-one relationship that lists the project name -> app.
    # Example:
    # /home/ilsdev|three.js
    # ilsdev1|monkey-mat.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|estj-bone-2-anim.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|monkey-anim.js|three.js/essential-threejs/assets/models/exported
    perl -n -e 'use File::Basename; print(dirname($_)."|".basename($_));' "$FILE_LIST" | sed 's,'"${HOME}"'/,'"${HOSTNAME}"'|,g' | pipe.pl -oc0,c2,c1 | pipe.pl -zc1 > $PROJECT_LIST
    # Read the $FILE_LIST line by line and analyse for references to other scripts.
    echo >/tmp/audit.depend.lst
    echo >/tmp/audit.connect.lst
    echo >/tmp/audit.location.lst
    while IFS= read -r file_path; do
        if echo "$file_path" | egrep -i "*.js$" >/dev/null 2>/dev/null; then
            echo "skipping $file_path"
        else
            # Get the name of the file but the script doesn't process links, so don't emit an error of file not found.
            local file_name=$(echo "$file_path" | perl -ne 'use File::Basename; print(basename($_));' -)
            if [ -z "$file_name" ]; then
                continue
            fi
            # Add the file to the location table
            echo "$HOSTNAME|$file_name|$file_path" >>/tmp/audit.location.lst
            echo -n "["`date +'%Y-%m-%d %H:%M:%S'`"] analysing $file_name"
            cat "$file_path" 2>/dev/null | sed -e '/^[ \t]*#/d' | env HOST="$HOSTNAME|$file_name" perl -n -e 'while(m/(?=.*\W)\w{2,}\.(pl|sh|py|js)\s/g){ chomp($script=$&);print("$ENV{HOST}|$script\n"); }' - >>/tmp/audit.depend.lst
            echo -n ", dependencies: done"
            # Collect any information about whether this script talks with other servers. The markers are
            # 'ssh', 'mysql', 'sftp', 'HTTP', 'scp', IPs and hostnames.
            #  (\w+((\.\w+)+)?\@\w+((\.\w+)+)?)|((?=\s?)(mysql|ssh|scp|sftp|mailx)\s)|(http:\/\/\w+((\.\w+)+)?)|(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})
            cat "$file_path" 2>/dev/null | sed -e '/^[ \t]*#/d' | env HOST="$HOSTNAME|$file_name" perl -n -e 'while(m/(\w+((\.\w+)+)?\@\w+((\.\w+)+)?)|((?=\s?)(mysql|ssh|scp|sftp|mailx)\s)|(http:\/\/\w+((\.\w+)+)?)|(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/gi){ chomp($server=$&);$server=q/localhost/ if (! $server);print("$ENV{HOST}|$server\n"); }' - >>/tmp/audit.connect.lst
            echo ", connections: done"
        fi
    done < "$FILE_LIST"
    # Clean the Dependent table of duplicates, and files that reference themselves.
    cat /tmp/audit.depend.lst | pipe.pl -Bc1,c2 -zc1 | pipe.pl -dc0,c1,c2 >$DEPEND_LIST
    cat /tmp/audit.connect.lst | pipe.pl -Bc1,c2 -zc1 | pipe.pl -dc0,c1,c2 >$CONNECT_LIST
    cat /tmp/audit.location.lst | pipe.pl -zc1 >$LOCATION_LIST
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

# Creates a SQL database (Sqlite3) and if possible, populates it with data from *.sql files
# in the current directory.
# param:  none
build_database()
{
    # DEPEND
    # ilsdev1|ClaimsReturnedToMissing.sh|dischargeitemchargeitem.pl
    # ilsdev1|ClaimsReturnedToMissing.sh|setscriptenvironment.sh
    # ilsdev1|FixItemLibraryForItemTransfers.sh|FixItemLibraryForItemTransfers_EditItem_Edits.sh
    local server="server"
    local script="script"
    local c0="dependent"
    local c1=""
    local c2=""
    local c3=""
    local c4=""
    sqlite3 $DBASE <<END_SQL
CREATE TABLE IF NOT EXISTS $DEPEND (
    $server CHAR(60),
    $script CHAR(128),
    $c0 CHAR(128),
    PRIMARY KEY ($server, $script, $c0)
);
END_SQL
    # And indices
    sqlite3 $DBASE <<END_SQL
CREATE UNIQUE INDEX IF NOT EXISTS idx_depend_server_script ON $DEPEND ($server, $script, $c0);
END_SQL
    if [ -s "$DEPEND_LIST" ]; then
        # Load the data
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] preparing sql $DEPEND statements"
        env table="$DEPEND" env a="$server" env b="$script" env c="$c0" perl -ne 'chomp(@v = split(m/\|/)); print(qq/INSERT OR REPLACE INTO $ENV{table} ($ENV{a}, $ENV{b}, $ENV{c}) VALUES ("$v[0]", "$v[1]", "$v[2]");\n/);' $DEPEND_LIST >$DEPEND_LIST.sql
        # Then load with:
        if sqlite3 $DBASE <$DEPEND_LIST.sql; then
            echo "$DEPEND_LIST.sql loaded."
            rm "$DEPEND_LIST.sql" 2>/dev/null
        else
            echo "**error failed to load $DEPEND_LIST.sql" >&2
        fi
    else
        echo "Created table $DEPEND and indices, no data to load." >&2
    fi
    
    
    c0="namespace"
    # PROJECT
    # ilsdev1|monkey-mat.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|estj-bone-2-anim.js|three.js/essential-threejs/assets/models/exported
    # ilsdev1|monkey-anim.js|three.js/essential-threejs/assets/models/exported
    sqlite3 $DBASE <<END_SQL
CREATE TABLE IF NOT EXISTS $PROJECT (
    $server CHAR(60),
    $script CHAR(128),
    $c0 CHAR(2048),
    PRIMARY KEY ($server, $script, $c0)
);
END_SQL
    # And indices
    sqlite3 $DBASE <<END_SQL
CREATE UNIQUE INDEX IF NOT EXISTS idx_project_server_script ON $PROJECT ($server, $script, $c0);
END_SQL
    # Load the data
    if [ -s "$PROJECT_LIST" ]; then
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] preparing sql $PROJECT statements"
        env table="$PROJECT" env a="$server" env b="$script" env c="$c0" perl -ne 'chomp(@v = split(m/\|/)); print(qq/INSERT OR REPLACE INTO $ENV{table} ($ENV{a}, $ENV{b}, $ENV{c}) VALUES ("$v[0]", "$v[1]", "$v[2]");\n/);' $PROJECT_LIST >$PROJECT_LIST.sql
        # Then load with:
        if sqlite3 $DBASE <$PROJECT_LIST.sql; then
            echo "$PROJECT_LIST.sql loaded."
            rm "$PROJECT_LIST.sql" 2>/dev/null
        else
            echo "**error failed to load $PROJECT_LIST.sql" >&2
        fi
    else
        echo "Created table $PROJECT and indices, no data to load." >&2
    fi
    
    
    c0="resource"
    # CONNECT
    # ilsdev1|ClaimsReturnedToMissing.sh|mailx
    # ilsdev1|FixItemLibraryForItemTransfers.sh|ilsadmins@epl.ca
    # ilsdev1|PrepareAndTransferBIBsAndAuthsToBackstage.pl|mailx
    sqlite3 $DBASE <<END_SQL
CREATE TABLE IF NOT EXISTS $CONNECT (
    $server CHAR(60),
    $script CHAR(128),
    $c0 CHAR(128),
    PRIMARY KEY ($server, $script, $c0)
);
END_SQL
    # And indices
    sqlite3 $DBASE <<END_SQL
CREATE UNIQUE INDEX IF NOT EXISTS idx_connect_server_script ON $CONNECT ($server, $script, $c0);
END_SQL
    # Load the data
    if [ -s "$CONNECT_LIST" ]; then
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] preparing sql $CONNECT statements"
        env table="$CONNECT" env a="$server" env b="$script" env c="$c0" perl -ne 'chomp(@v = split(m/\|/)); print(qq/INSERT OR REPLACE INTO $ENV{table} ($ENV{a}, $ENV{b}, $ENV{c}) VALUES ("$v[0]", "$v[1]", "$v[2]");\n/);' $CONNECT_LIST >$CONNECT_LIST.sql
        # Then load with:
        if sqlite3 $DBASE <$CONNECT_LIST.sql; then
            echo "$CONNECT_LIST.sql loaded."
            rm "$CONNECT_LIST.sql" 2>/dev/null
        else
            echo "**error failed to load $CONNECT_LIST.sql" >&2
        fi
    else
        echo "Created table $CONNECT and indices, no data to load." >&2
    fi
    
    c0="path"
    # LOCATION
    # ilsdev1|Readme.sh|/home/ilsdev/reports/staffcheckouts/Readme.sh
    # ilsdev1|create_report.sh|/home/ilsdev/reports/create_report.sh
    sqlite3 $DBASE <<END_SQL
CREATE TABLE IF NOT EXISTS $LOCATION (
    $server CHAR(60),
    $script CHAR(128),
    $c0 CHAR(2048),
    PRIMARY KEY ($server, $script, $c0)
);
END_SQL
    # Indices
    sqlite3 $DBASE <<END_SQL
CREATE UNIQUE INDEX IF NOT EXISTS idx_location_server_script ON $LOCATION ($server, $script, $c0);
END_SQL
    # Load the data
    if [ -s "$LOCATION_LIST" ]; then
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] preparing sql $LOCATION statements"
        env table="$LOCATION" env a="$server" env b="$script" env c="$c0" perl -ne 'chomp(@v = split(m/\|/)); print(qq/INSERT OR REPLACE INTO $ENV{table} ($ENV{a}, $ENV{b}, $ENV{c}) VALUES ("$v[0]", "$v[1]", "$v[2]");\n/);' $LOCATION_LIST >$LOCATION_LIST.sql
        # Then load with:
        if sqlite3 $DBASE <$LOCATION_LIST.sql; then
            echo "$LOCATION_LIST.sql loaded."
            rm "$LOCATION_LIST.sql" 2>/dev/null
        else
            echo "**error failed to load $LOCATION_LIST.sql" >&2
        fi
    else
        echo "Created table $LOCATION and indices, no data to load." >&2
    fi
    
    c0="minute"
    c1="hour"
    c2="dom"
    c3="month"
    c4="dow"
    # SCHED
    # ilsdev1|backuprotate.sh|30|21|*|*|*
    # ilsdev1|run.sh|00|21|*|*|2,3,4,5
    # ilsdev1|run.sh|00|06|*|*|1
    sqlite3 $DBASE <<END_SQL
CREATE TABLE IF NOT EXISTS $SCHED (
    $server CHAR(60),
    $script CHAR(128),
    $c0 CHAR(256),
    $c1 CHAR(256),
    $c2 CHAR(256),
    $c3 CHAR(256),
    $c4 CHAR(256),
    PRIMARY KEY ($server, $script)
);
END_SQL
    # Indices
    sqlite3 $DBASE <<END_SQL
CREATE UNIQUE INDEX IF NOT EXISTS idx_sched_server_script ON $SCHED ($server, $script);
END_SQL
    # Load the data
    if [ -s "$SCHED_LIST" ]; then
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] preparing sql $SCHED statements"
        env table="$SCHED" env a="$server" env b="$script" env c="$c0" env d="$c1" env e="$c2" env f="$c3" env g="$c4" perl -ne 'chomp(@v = split(m/\|/)); print(qq/INSERT OR REPLACE INTO $ENV{table} ($ENV{a}, $ENV{b}, $ENV{c}, $ENV{d}, $ENV{e}, $ENV{f}, $ENV{g}) VALUES ("$v[0]", "$v[1]", "$v[2]", "$v[3]", "$v[4]", "$v[5]", "$v[6]");\n/);' $SCHED_LIST >$SCHED_LIST.sql
        # Then load with:
        if sqlite3 $DBASE <$SCHED_LIST.sql; then
            echo "$SCHED_LIST.sql loaded."
            rm "$SCHED_LIST.sql" 2>/dev/null
        else
            echo "**error failed to load $SCHED_LIST.sql" >&2
        fi
    else
        echo "Created table $SCHED and indices, no data to load." >&2
    fi
}

# Removes all and only the list files audit creates.
# param:  none
remove_lst_files()
{
    for THIS_FILE in "${OUTPUT_FILES[@]}"
    do
        echo "removing $THIS_FILE..." >&2
        rm "$THIS_FILE" 2>/dev/null
    done
}

# Prepares the tarball and cleans up.
# param:  none
clean_up()
{
    if [ -s "$HOSTNAME.audit.tar" ]; then
        # remove, don't update the tarball.
        rm "$HOSTNAME.audit.tar" 2>/dev/null
    fi
    tar cvf $HOSTNAME.audit.tar "$FILE_LIST" "$DEPEND_LIST" "$SCHED_LIST" "$PROJECT_LIST" "$CONNECT_LIST" "$LOCATION_LIST"
    if [ -s "$HOSTNAME.audit.tar" ]; then
        remove_lst_files
    else
        echo "**error: the tarball of audit files wasn't created!" >&2
        exit 3
    fi
}

############################# End of Functions #################################


# Loop through the file list and pull out relevant info in pipe-delimited files appending as we go.
while getopts ":aAcdRsx?" opt; do
  case $opt in
    A)  echo "-A to audit and create all tables as flat files. See (-d) to create the database." >&2
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SCHED_LIST." >&2
        audit_cron
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] conducting audit." >&2
        audit_scripts
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding data to the database." >&2
        build_database
        clean_up
        ;;
    a)  echo "-a to audit scripts and create flat files only. See (-d) to create the database." >&2
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SCHED_LIST." >&2
        audit_cron
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] conducting audit." >&2
        audit_scripts
        clean_up
        ;;
    c)	echo "-c to audit the crontab only." >&2 
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] adding cron entries to $SCHED_LIST." >&2
        audit_cron
        ;;
    d)	echo "-d to create database from existing files." >&2 
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] building database: $DBASE." >&2
        build_database
        ;;
    R)	echo "-R to rebuild the database from existing tarballs." >&2 
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] building database: $DBASE." >&2
        if [ -e "$DBASE" ]; then
            ANSWER=$(confirm "re-create $DBASE and load any data ")
            if [ "$ANSWER" == "$FALSE" ]; then
                echo "Nothing to do. exiting" >&2
                exit 1
            else
                if ls *.tar >/dev/null 2>/dev/null; then
                    rm "$DBASE" 2>/dev/null
                else
                    echo "no tar files to load. exiting." >&2
                fi
            fi
        fi
        echo "["`date +'%Y-%m-%d %H:%M:%S'`"] creating $DBASE and loading data." >&2
        for TARBALL in $(ls *.audit.tar 2>/dev/null); do
            echo "working on $TARBALL..." >&2
            tar xvf "$TARBALL"
            build_database
            remove_lst_files
        done
        ;;
    s)  echo "-s to display database schema." >&2
        if [ -s "$DBASE" ]; then
            echo ".schema" | sqlite3 $DBASE
        else
            echo "$DBASE doesn't exist yet. I can create it, and load any data in "`pwd` >&2
            ANSWER=$(confirm "re-create $DBASE and load any data ")
            if [ "$ANSWER" == "$FALSE" ]; then
                echo "Nothing to do. exiting" >&2
                exit 1
            else
                echo "["`date +'%Y-%m-%d %H:%M:%S'`"] creating $DBASE and loading data." >&2
                build_database
                echo ".schema" | sqlite3 $DBASE
            fi
        fi
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
