#!/bin/bash
# This script echoes all the subtitle languages of an MKV file
# in a comma-separated list. The MKV file should be given as the 1st
# argument to this script.

declare -a mkvinfo_list
declare -a lang_list
declare -a lang_list_sorted

if=$(readlink -f "$1")
if_bn=$(basename "$if")
if_bn_lc="${if_bn,,}"

regex_sub='^.*Track type: subtitles'
regex_lang='^.*Language( \(.*\)){0,1}: '
regex_name='^.*Name: '

usage () {
	printf '%s\n\n' "Usage: $(basename "$0") [mkv]"
	exit
}

if [[ ! -f $if || ${if_bn_lc##*.} != 'mkv' ]]; then
	usage
fi

command -v mkvinfo 1>&- 2>&- || exit

switch=0
count=0

mapfile -t mkv_info_list < <(mkvinfo "$if" 2>&-)

for (( i = 0; i < ${#mkv_info_list[@]}; i++ )); do
	line="${mkv_info_list[${i}]}"

	if [[ $line =~ $regex_sub ]]; then
		switch=1
	fi

	if [[ $switch -eq 1 ]]; then
		if [[ $line =~ $regex_lang ]]; then
			lang_list+=( "$(sed -E "s/${regex_lang}//" <<<"$line")" )
			switch=0
		fi

		if [[ $line =~ $regex_name ]]; then
			lang_list+=( "$(sed -E "s/${regex_name}//" <<<"$line")" )
			switch=0
		fi
	fi
done

sort_list () {
	for (( i = 0; i < ${#lang_list[@]}; i++ )); do
		printf '%s\n' "${lang_list[${i}]}"
	done | sort
}

mapfile -t lang_list_sorted < <(sort_list)

for (( i = 0; i < ${#lang_list_sorted[@]}; i++ )); do
	line="${lang_list_sorted[${i}]}"

	if [[ $line ]]; then
		if [[ $count -eq 0 ]]; then
			printf "Subtitles: %s" "${line^}"
		else
			printf ", %s" "${line^}"
		fi

		let count++
	fi
done

printf '\n' 
