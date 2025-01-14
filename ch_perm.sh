#!/bin/bash

# This script recursively changes the owner (and group) of input files /
# directories, to either the current user or root. It also changes read
# / write permissions to match. In the case of root, all input files
# and directories are write-protected.

usage () {
	printf '\n%s\n\n' "Usage: $(basename "$0") [user|root] [file / directory]"
	exit
}

ch_perm () {
	sudo chown -v -R "${owner}:${owner}" "$1"

	if [[ $owner == "$USER" ]]; then
		sudo chmod -v -R +rw "$1"
	fi

	if [[ $owner == 'root' ]]; then
		sudo chmod -v -R ugo-w "$1"
	fi

	if [[ -f $1 ]]; then
		return
	fi

	mapfile -t dirs < <(sudo find "$1" -type d 2>&-)

	for (( i = 0; i < ${#dirs[@]}; i++ )); do
		dn="${dirs[${i}]}"
		sudo chmod -v ugo+x "$dn"
	done
}

declare owner

case "$1" in
	'user')
		owner="$USER"
	;;
	'root')
		owner='root'
	;;
	*)
		usage
	;;
esac

shift

while [[ $# -gt 0 ]]; do
	fn=$(readlink -f "$1")

	if [[ ! -f $fn && ! -d $fn ]]; then
		usage
	fi

	ch_perm "$fn"

	shift
done
