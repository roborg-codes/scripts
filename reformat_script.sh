#!/bin/bash

# This is just a simple script to reformat / clean up my old shell
# scripts. My formatting style as well as choice of text editor have
# changed over the years. I now use the Geany text editor, which has a
# page width of 72 characters.

# This script will:

# * Replace individual spaces at the beginning of each line with tabs
# (4 spaces / tab).
# * Reduce the number of successive empty lines to a maximum of 1.
# * Remove space at the beginning of comment lines.
# * Reduce multiple #s to just 1 # in comment lines.
# * Remove space at the end of lines.
# * Replace multiple successive spaces in comments with just one space.
# * Reduce the total length of comment lines to 72 characters.

set -eo pipefail

# If the script isn't run with sudo / root privileges, quit.
if [[ $EUID -ne 0 ]]; then
	printf '\n%s\n\n' "You need to be root to run this script!"
	exit
fi

# If argument is not a real file, print usage and quit.
if [[ ! -f $1 ]]; then
	printf '\n%s\n\n' "Usage: $(basename "$0") [file]"
	exit
fi

if=$(readlink -f "$1")
bn=$(basename "$if")
session="${RANDOM}-${RANDOM}"
of="/dev/shm/${bn%.*}-${session}.txt"

limit=72
regex1='^([[:blank:]]*)(#+)([[:blank:]]*)'
regex2='^[[:blank:]]+'
regex3='[[:blank:]]+$'
regex4='[[:blank:]]+'
regex5='^( {4})'
regex6='^#!'

declare -a lines_in lines_out

tab=$(printf '\t')

# Reads the input file.
mapfile -t lines_in < <(tr -d '\r' <"$if")

# Creates a function called 'next_line', which will shift the line
# variables by 1 line.
next_line () {
	(( i += 1 ))
	(( j = (i + 1) ))

	line_this="${lines_in[${i}]}"
	line_next="${lines_in[${j}]}"
}

# Creates a function called 'if_shebang', which will check if the
# current line is a shebang, and add an empty line after if needed.
if_shebang () {
	if [[ $line_this =~ $regex6 ]]; then
		lines_out+=("$line_this")

		if [[ -n $line_next ]]; then
			lines_out+=('')
		fi

		next_line
	fi
}

# Creates a function called 'reformat_comments', which will reformat
# comment lines if they're longer than the set limit.
reformat_comments () {
	declare start stop switch
	declare -a buffer

	start="$i"

	switch=0

	if [[ ! $line_this =~ $regex1 ]]; then
		lines_out+=("$line_this")

		return
	fi

	while [[ $line_this =~ $regex1 ]]; do
		mapfile -t words < <(sed -E -e "s/${regex1}//" -e "s/${regex3}//" -e "s/${regex4}/\n/g" <<<"$line_this")
		string="# ${words[@]}"
		chars="${#string}"

		if [[ $chars -gt $limit ]]; then
			switch=1
		fi

		buffer+=("${words[@]}")

		next_line
	done

	if [[ $switch -eq 0 ]]; then
		(( stop = (i - start) ))

		lines_out+=("${lines_in[@]:${start}:${stop}}")
	fi

	if [[ $switch -eq 1 ]]; then
		string='#'
		chars=1

		end=$(( ${#buffer[@]} - 1 ))

		for (( k = 0; k < ${#buffer[@]}; k++ )); do
			word="${buffer[${k}]}"

			(( chars += (${#word} + 1) ))

			if [[ $chars -le $limit ]]; then
				string+=" ${word}"
			else
				lines_out+=("$string")

				string="# ${word}"
				(( chars = (${#word} + 2) ))
			fi

			if [[ $k -eq $end ]]; then
				lines_out+=("$string")
			fi
		done
	fi

	(( i -= 1 ))
}

# Creates a function called 'reformat_lines', which will fix indentation
# among other things.
reformat_lines () {
	declare indent

	if [[ $line_this =~ $regex1 ]]; then
		line_this=$(sed -E -e "s/${regex1}/# /" -e "s/${regex4}/ /g" <<<"$line_this")
	fi

	while [[ $line_this =~ $regex5 ]]; do
		line_this=$(sed -E "s/${regex5}//" <<<"$line_this")
		indent+="$tab"
	done

	line_this="${indent}${line_this}"

	if [[ $line_this =~ $regex3 ]]; then
		line_this=$(sed -E "s/${regex3}//" <<<"$line_this")
	fi

	lines_out+=("$line_this")
}

# Creates a function called 'reset_arrays', which will reset the line
# arrays in-between loops.
reset_arrays () {
	lines_in=("${lines_out[@]}")
	lines_out=()
}

for (( i = 0; i < ${#lines_in[@]}; i++ )); do
	(( j = (i + 1) ))

	line_this="${lines_in[${i}]}"
	line_next="${lines_in[${j}]}"

	if_shebang

	if [[ -z $line_this && -z $line_next ]]; then
		continue
	fi

	reformat_comments
done

reset_arrays

for (( i = 0; i < ${#lines_in[@]}; i++ )); do
	(( j = (i + 1) ))

	line_this="${lines_in[${i}]}"
	line_next="${lines_in[${j}]}"

	if_shebang

	reformat_lines
done

# If the last line is not empty, add an empty line.
if [[ -n ${lines_out[-1]} ]]; then
	lines_out+=('')
fi

# Prints the altered lines to the temporary file name.
printf '%s\n' "${lines_out[@]}" > "$of"

# Copies permissions and modification time from the original file to the
# new file.
chmod --reference="${if}" "$of"
chown --reference="${if}" "$of"
touch -r "$if" "$of"

# Replaces the original file with the new file.
mv "$of" "$if"
