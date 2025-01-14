#!/bin/bash

# This script is meant to take an input BIN/CUE file, extract the raw
# track(s) (data / audio) in whatever format the user has specified
# through script arguments. The script simply separates all the tracks
# of BIN/CUE files.

# Available audio formats are:
# * cdr (native CD audio)
# * ogg (Ogg Vorbis)
# * flac (Free Lossless Audio Codec)

# If no format is specified as an argument, the script will extract all
# 3 formats, and create CUE sheets for all 3 formats as well.

# The original purpose of the script is to take DOS games that have CD
# audio, and getting rid of the need to store the uncompressed audio.
# Ogg Vorbis is a lossy codec, so the files are much smaller and near
# the same quality. In the case of FLAC, it's a lossless format so the
# quality is identical to native CD audio. The only difference is FLAC
# is losslessly compressed so the files are slightly smaller. The
# generated CUE sheets can be used with DOSBox, using the 'IMGMOUNT'
# command.

# https://www.dosbox.com/wiki/IMGMOUNT

# Another use case for this script is to simply extract the OST from
# games, to listen to.

# The script will work with all kinds of games, including PS1 and Sega
# Saturn games. All that's required is that the disc image is in the
# BIN/CUE format. There's some other emulators out there that can
# handle FLAC and Ogg Vorbis tracks, like Mednafen, but support is not
# widespread. The main point of the script is being able to quickly
# extract music from BIN/CUE files.

# Yet another use case is to just split a BIN/CUE into its separate
# tracks, with the '-cdr' argument, without encoding the audio. Any
# BIN/CUE, that has multiple tracks, can be split. It doesn't need to
# have audio tracks.

# Pregaps are automatically stripped from the output BIN files, and are
# only symbolically represented in the generated CUE sheets as PREGAP
# commands. In the rare case that the disc has a hidden bonus track in
# the pregap for the 1st track, that will be stripped also as the script
# has no way of knowing the difference. If the pregap is longer than
# a couple of seconds, then it might contain a hidden track.

# It's possible to do a byteswap on the audio tracks (to switch the
# endianness / byte order), through the optional '-byteswap' argument.
# This is needed in some cases, or audio tracks will be white noise if
# the endianness is wrong. So, it's easy to tell whether or not the byte
# order is correct.

# The script is able to process CUE sheets that contain multiple FILE
# commands (list multiple BIN files). As an example, Redump will use 1
# BIN file / track, so that can be processed by the script directly in
# this case, without having to merge the BIN/CUE first.

# Earlier versions of the script used to depend on 'bchunk', which is a
# good program, but not needed anymore as other functions have replaced
# it.

if=$(readlink -f "$1")
if_dn=$(dirname "$if")
if_bn=$(basename "$if")
if_bn_lc="${if_bn,,}"

# Creates a function, called 'usage', which will print usage
# instructions and then quit.
usage () {
	cat <<USAGE

Usage: $(basename "$0") [cue] [...]

	Optional arguments:

-cdr
	Audio tracks will be output exclusively in CD audio format.

-ogg
	Audio tracks will be output exclusively in Ogg Vorbis.

-flac
	Audio tracks will be output exclusively in FLAC.

-sox
	Uses 'sox' instead of 'ffmpeg' to convert CD audio to WAV.

-byteswap
	Reverses the endianness / byte order of the audio tracks.

USAGE

	exit
}

# If input is not a real file, or it has the wrong extension, print
# usage and quit.
if [[ ! -f $if || ${if_bn_lc##*.} != 'cue' ]]; then
	usage
fi

declare mode byteswap session of_name of_dn
declare -A audio_types audio_types_run

audio_types=([cdr]='cdr' [ogg]='wav' [flac]='wav')

mode='ffmpeg'
byteswap=0

# The loop below handles the arguments to the script.
shift

while [[ $# -gt 0 ]]; do
	case "$1" in
		'-cdr')
			audio_types_run[cdr]=1

			shift
		;;
		'-ogg')
			audio_types_run[ogg]=1

			shift
		;;
		'-flac')
			audio_types_run[flac]=1

			shift
		;;
		'-sox')
			mode='sox'

			shift
		;;
		'-byteswap')
			byteswap=1

			shift
		;;
		*)
			usage
		;;
	esac
done

if [[ ${#audio_types_run[@]} -eq 0 ]]; then
	for type in "${!audio_types[@]}"; do
		audio_types_run["${type}"]=1
	done
fi

session="${RANDOM}-${RANDOM}"

of_name="${if_bn_lc%.*}"
of_name=$(sed -E 's/[[:blank:]]+/_/g' <<<"$of_name")

of_dn="${PWD}/${of_name}-${session}"

declare -a format
declare -A regex

format[0]='^[0-9]+$'
format[1]='^([0-9]{2}):([0-9]{2}):([0-9]{2})$'
format[2]='[0-9]{2}:[0-9]{2}:[0-9]{2}'
format[3]='^(FILE) (.*) (.*)$'
format[4]='^(TRACK) ([0-9]{2,}) (.*)$'
format[5]="^(PREGAP) (${format[2]})$"
format[6]="^(INDEX) ([0-9]{2,}) (${format[2]})$"
format[7]="^(POSTGAP) (${format[2]})$"

regex[blank]='^[[:blank:]]*(.*)[[:blank:]]*$'
regex[path]='^(.*[\\\/])'
regex[fn]='^(.*)\.([^.]*)$'

regex[data]='^MODE([0-9])\/([0-9]{4})$'
regex[audio]='^AUDIO$'

declare type block_size track_n track_type
declare -a tracks_file tracks_type tracks_sector tracks_start tracks_length tracks_total
declare -a files_cdr files_wav of_cue_cdr of_cue_ogg of_cue_flac
declare -A if_cue gaps

# Creates a function, called 'check_cmd', which will check if the
# necessary commands are installed. If any of the commands are missing
# print them and quit.
check_cmd () {
	declare -a missing_pkg

	for cmd in "$@"; do
		command -v "$cmd" 1>&-

		if [[ $? -ne 0 ]]; then
			missing_pkg+=("$cmd")
		fi
	done

	if [[ ${#missing_pkg[@]} -gt 0 ]]; then
		printf '\n%s\n\n' 'You need to install the following through your package manager:'
		printf '%s\n' "${missing_pkg[@]}"
		printf '\n'

		exit
	fi
}

# Creates a function, called 'run_cmd', which will be used to run
# external commands, capture their output, and print the output (and
# quit) if the command fails.
run_cmd () {
	declare exit_status
	declare -a cmd_stdout

	mapfile -t cmd_stdout < <(eval "$@" 2>&1; printf '%s\n' "$?")

	exit_status="${cmd_stdout[-1]}"
	unset -v cmd_stdout[-1]

# Prints the output from the command if it has a non-zero exit status,
# and then quits.
	if [[ $exit_status != '0' ]]; then
		printf '%s\n' "${cmd_stdout[@]}"
		printf '\n'

		exit
	fi
}

# Creates a function, called 'get_files', which will be used to generate
# file lists to be used by other functions.
get_files () {
	for glob in "$@"; do
		compgen -G "$glob"
	done | sort -n
}

# Creates a function, called 'time_convert', which converts track
# timestamps back and forth between the time (mm:ss:ff) format and
# frames / sectors.
time_convert () {
	time="$1"

	declare m s f

	m=0
	s=0
	f=0

# If argument is in the mm:ss:ff format...
	if [[ $time =~ ${format[1]} ]]; then
		m="${BASH_REMATCH[1]#0}"
		s="${BASH_REMATCH[2]#0}"
		f="${BASH_REMATCH[3]#0}"

# Converting minutes and seconds to frames, and adding all the numbers
# together.
		m=$(( m * 60 * 75 ))
		s=$(( s * 75 ))

		time=$(( m + s + f ))

# If argument is in the frame format...
	elif [[ $time =~ ${format[0]} ]]; then
		f="$time"

		s=$(( f / 75 ))
		m=$(( s / 60 ))

		f=$(( f % 75 ))
		s=$(( s % 60 ))

		time=$(printf '%02d:%02d:%02d' "$m" "$s" "$f")
	fi

	printf '%s' "$time"
}

# Creates a function, called 'read_cue', which will read the source CUE
# sheet, get all the relevant information from it and store that in
# variables. It will also add full path to file names listed in the CUE
# sheet.
read_cue () {
	declare line file_n
	declare -a lines files not_found wrong_format wrong_mode

	declare -a error_types
	declare -A error_msgs

	file_n=0
	track_n=0

	error_types=('not_found' 'wrong_format' 'wrong_mode')
	error_msgs[no_files]='No files were found in CUE sheet!'
	error_msgs[not_found]='The files below were not found:'
	error_msgs[wrong_format]='The files below have the wrong format:'
	error_msgs[wrong_mode]='The tracks below have an unrecognized mode:'

# Creates a function, called 'handle_command', which will process each
# line in the CUE sheet and store all the relevant information in the
# 'if_cue' hash.
	handle_command () {
# If line is a FILE command...
		if [[ $line =~ ${format[3]} ]]; then
			match=("${BASH_REMATCH[@]:1}")

# Strips quotes, and path that may be present in the CUE sheet, and adds
# full path to the basename.
			fn=$(tr -d '"' <<<"${match[1]}" | sed -E "s/${regex[path]}//")
			fn="${if_dn}/${fn}"

# If file can't be found, or format isn't binary, then it's useless even
# trying to process this CUE sheet.
			if [[ ! -f $fn ]]; then
				not_found+=("$fn")
			fi

			if [[ ${match[2]} != 'BINARY' ]]; then
				wrong_format+=("$fn")
			fi

			files+=("$fn")

			(( file_n += 1 ))

			if_cue["${file_n},filename"]="$fn"
			if_cue["${file_n},file_format"]="${match[2]}"

			return
		fi

# If line is a TRACK command...
		if [[ $line =~ ${format[4]} ]]; then
			match=("${BASH_REMATCH[@]:1}")

			track_n="${match[1]#0}"

# Saves the file number associated with this track.
			tracks_file["${track_n}"]="$file_n"

# Saves the current track number (and in effect, every track number) in
# an array so the exact track numbers can be referenced later.
			tracks_total+=("$track_n")

# Figures out if this track is data or audio, and saves the sector size.
# Typical sector size is 2048 bytes for data CDs, and 2352 for audio.
			if [[ ${match[2]} =~ ${regex[data]} ]]; then
				tracks_type["${track_n}"]='data'
				tracks_sector["${track_n}"]="${BASH_REMATCH[2]}"
			fi

			if [[ ${match[2]} =~ ${regex[audio]} ]]; then
				tracks_type["${track_n}"]='audio'
				tracks_sector["${track_n}"]=2352
			fi

# If the track mode was not recognized, then it's useless even trying to
# process this CUE sheet.
			if [[ -z ${tracks_type[${track_n}]} ]]; then
				wrong_mode+=("$track_n")
			fi

			if_cue["${track_n},track_number"]="${match[1]}"
			if_cue["${track_n},track_mode"]="${match[2]}"

			return
		fi

# If line is a PREGAP command...
		if [[ $line =~ ${format[5]} ]]; then
			match=("${BASH_REMATCH[@]:1}")

			frames=$(time_convert "${match[1]}")
			if_cue["${track_n},pregap"]="$frames"

			return
		fi

# If line is an INDEX command...
		if [[ $line =~ ${format[6]} ]]; then
			match=("${BASH_REMATCH[@]:1}")

			index_n="${match[1]#0}"

			frames=$(time_convert "${match[2]}")
			if_cue["${track_n},index,${index_n}"]="$frames"

			return
		fi

# If line is a POSTGAP command...
		if [[ $line =~ ${format[7]} ]]; then
			match=("${BASH_REMATCH[@]:1}")

			frames=$(time_convert "${match[1]}")
			if_cue["${track_n},postgap"]="$frames"

			return
		fi
	}

# Reads the source CUE sheet and processes the lines.
	mapfile -t lines < <(tr -d '\r' <"$if" | sed -E "s/${regex[blank]}/\1/")

	for (( i = 0; i < ${#lines[@]}; i++ )); do
		line="${lines[${i}]}"
		handle_command
	done

# If errors were found, print them and quit.
	if [[ ${#files[@]} -eq 0 ]]; then
		printf '\n%s\n\n' "${error_msgs[no_files]}"

		exit
	fi

	for error in "${error_types[@]}"; do
		declare elements msg_ref list_ref

		elements=0

		case "$error" in
			'not_found')
				elements="${#not_found[@]}"
			;;
			'wrong_format')
				elements="${#wrong_format[@]}"
			;;
			'wrong_mode')
				elements="${#wrong_mode[@]}"
			;;
		esac

		if [[ $elements -eq 0 ]]; then
			continue
		fi

		msg_ref="error_msgs[${error}]"
		list_ref="${error}[@]"

		printf '\n%s\n\n' "${!msg_ref}"
		printf '%s\n' "${!list_ref}"
		printf '\n'

		exit
	done
}

# Creates a function, called 'get_gaps', which will get pregap and
# postgap from the CUE sheet for the track number given as argument.
# If there's both a pregap specified using the PREGAP command and INDEX
# command, those values will be added together. However, a CUE sheet is
# highly unlikely to specify a pregap twice like that.
get_gaps () {
	declare pregap_ref postgap_ref

# If the CUE sheet contains PREGAP or POSTGAP commands, save that in the
# 'gaps' hash. Add it to the value that might already be there, cause of
# pregaps specified by INDEX commands.
	pregap_ref="if_cue[${track_n},pregap]"
	postgap_ref="if_cue[${track_n},postgap]"

	if [[ -n ${!pregap_ref} ]]; then
		(( gaps[${track_n},pre] += ${!pregap_ref} ))
	fi

	if [[ -n ${!postgap_ref} ]]; then
		(( gaps[${track_n},post] += ${!postgap_ref} ))
	fi
}

# Creates a function, called 'get_length', which will get the start
# position, and length, (in bytes) of all tracks in the respective BIN
# files.
get_length () {
	declare this next
	declare bytes_pregap bytes_track bytes_total frames
	declare pregap_this_ref pregap_next_ref
	declare index0_this_ref index1_this_ref index0_next_ref index1_next_ref
	declare file_n_this_ref file_n_next_ref file_ref
	declare sector_ref start_ref

	bytes_total=0

# Creates a function, called 'get_size', which will get the track length
# by reading the size of the BIN file associated with this track. This
# function will also reset the 'bytes_total' variable to '0' (as the
# current track is last in the current BIN file).
	get_size () {
		declare size

		size=$(stat -c '%s' "${!file_ref}")

		bytes_track=$(( size - ${!start_ref} ))
		bytes_total=0

		tracks_length["${this}"]="$bytes_track"
	}

	for (( i = 0; i < ${#tracks_total[@]}; i++ )); do
		j=$(( i + 1 ))

		this="${tracks_total[${i}]}"
		next="${tracks_total[${j}]}"

		pregap_this_ref="gaps[${this},pre]"
		pregap_next_ref="gaps[${next},pre]"

		index0_this_ref="if_cue[${this},index,0]"
		index1_this_ref="if_cue[${this},index,1]"
		index0_next_ref="if_cue[${next},index,0]"
		index1_next_ref="if_cue[${next},index,1]"

		file_n_this_ref="tracks_file[${this}]"
		file_n_next_ref="tracks_file[${next}]"

		file_ref="if_cue[${!file_n_this_ref},filename]"

		sector_ref="tracks_sector[${this}]"

		start_ref="tracks_start[${this}]"

# If the CUE sheet specifies a pregap using the INDEX command, save that
# in the 'gaps' hash so it can later be converted to a PREGAP command.
		if [[ -n ${!index0_this_ref} && ${!pregap_this_ref} -eq 0 ]]; then
			gaps["${this},pre"]=$(( ${!index1_this_ref} - ${!index0_this_ref} ))
		fi

		if [[ -n ${!index0_next_ref} ]]; then
			gaps["${next},pre"]=$(( ${!index1_next_ref} - ${!index0_next_ref} ))
		fi

# Converts potential pregap frames to bytes, and adds it to the total
# bytes of the track position. This makes it possible for the
# 'copy_track' function to skip over the useless junk data in the
# pregap, when reading the track.
		bytes_pregap=$(( ${!pregap_this_ref} * ${!sector_ref} ))
		tracks_start["${this}"]=$(( bytes_total + bytes_pregap ))

# If this is the last track, get the track length by reading the size of
# the BIN file associated with this track.
		if [[ -z $next ]]; then
			get_size
			continue
		fi

# If the BIN file associated with this track is the same as the next
# track, get the track length by subtracting the start position of the
# current track from the position of the next track.
		if [[ ${!file_n_this_ref} -eq ${!file_n_next_ref} ]]; then
			frames=$(( ${!index1_next_ref} - ${!index1_this_ref} ))
			(( frames -= ${!pregap_next_ref} ))

			bytes_track=$(( frames * ${!sector_ref} ))
			(( bytes_total += (bytes_track + bytes_pregap) ))

			tracks_length["${this}"]="$bytes_track"
		fi

# If the BIN file associated with this track is different from the next
# track, get the track length by reading the size of the BIN file
# associated with this track.
		if [[ ${!file_n_this_ref} -ne ${!file_n_next_ref} ]]; then
			get_size
		fi
	done
}

# Creates a function, called 'loop_set', which will get the start
# positions, lengths, pregaps and postgaps for all tracks.
loop_set () {
	for (( i = 0; i < ${#tracks_total[@]}; i++ )); do
		track_n="${tracks_total[${i}]}"

		gaps["${track_n},pre"]=0
		gaps["${track_n},post"]=0
	done

	get_length

	for (( i = 0; i < ${#tracks_total[@]}; i++ )); do
		track_n="${tracks_total[${i}]}"

		get_gaps "$track_n"
	done
}

# Creates a function, called 'block_calc', which will be used to get the
# optimal block size to use in the 'copy_track' function when reading
# and writing tracks using 'dd'. Bigger block sizes makes the process
# faster, and the reason for being able to handle variable block sizes
# is that it's technically possible for a CUE sheet to contain tracks
# that have different sector sizes. And that will affect the start
# positions of tracks. This function counts down from 16KB, subtracting
# 4 bytes at each iteration of the loop, until a matching block size is
# found. We're using 4 byte increments cause that guarantees the block
# size will be divisible by the common CD sector sizes:
# * 2048
# * 2324
# * 2336
# * 2352
# * 2448
block_calc () {
	bytes1="$1"
	bytes2="$2"

	declare block_diff1 block_diff2

	block_size=16384

	block_diff1=$(( bytes1 % block_size ))
	block_diff2=$(( bytes2 % block_size ))

	until [[ $block_diff1 -eq 0 && $block_diff2 -eq 0 ]]; do
		(( block_size -= 4 ))

		block_diff1=$(( bytes1 % block_size ))
		block_diff2=$(( bytes2 % block_size ))
	done
}

# Creates a function, called 'copy_track', which will extract the raw
# binary data for the track number given as argument, from the BIN file.
copy_track () {
	declare file_n_ref file_ref start_ref length_ref
	declare of_bin ext block_size skip count
	declare -a args

	file_n_ref="tracks_file[${track_n}]"
	file_ref="if_cue[${!file_n_ref},filename]"

# Depending on whether the track type is data or audio, use the
# appropriate file name extension for the output file.
	case "$track_type" in
		'data')
			ext='bin'
		;;
		'audio')
			ext='cdr'
		;;
	esac

	of_bin=$(printf '%s/%s%02d.%s' "$of_dn" "$of_name" "$track_n" "$ext")

# Creates the first part of the 'dd' command.
	args=(dd if=\""${!file_ref}"\" of=\""${of_bin}"\")

# Does a byteswap if the script was run with the '-byteswap' option, and
# the track is audio.
	if [[ $byteswap -eq 1 && $track_type == 'audio' ]]; then
		args+=(conv=swab)
	fi

# Gets the start position, and length, of the track.
	start_ref="tracks_start[${track_n}]"
	length_ref="tracks_length[${track_n}]"

# Gets the optimal block size to use with 'dd'.
	block_calc "${!start_ref}" "${!length_ref}"

	args+=(bs=\""${block_size}"\")

	skip=$(( ${!start_ref} / block_size ))
	count=$(( ${!length_ref} / block_size ))

# If the start position of the track is greater than '0', skip blocks
# until the start of the track.
	if [[ $skip -gt 0 ]]; then
		args+=(skip=\""${skip}"\")
	fi

# If the track length is greater than '0', copy only a limited number of
# blocks.
	if [[ $count -gt 0 ]]; then
		args+=(count=\""${count}"\")
	fi

# Runs 'dd'.
	run_cmd "${args[@]}"
}

# Creates a function, called 'copy_all_tracks', which will extract the
# raw binary data for all tracks (i.e. separate the tracks).
copy_all_tracks () {
	for (( i = 0; i < ${#tracks_total[@]}; i++ )); do
		track_n="${tracks_total[${i}]}"
		track_type="${tracks_type[${track_n}]}"

		copy_track
	done

# Creates a file list to be used later in the 'create_cue' function.
	mapfile -t files_cdr < <(get_files "*.bin" "*.cdr")
}

# Creates a function, called 'cdr2wav', which will convert the extracted
# CDR files to WAV (using 'ffmpeg' or 'sox').
cdr2wav () {
	declare type_tmp if_cdr of_wav
	declare -a files

	type_tmp="${audio_types[${type}]}"

# If type is not 'wav' or WAV files have already been produced, return
# from this function.
	if [[ $type_tmp != 'wav' || ${#files_wav[@]} -gt 0 ]]; then
		return
	fi

	mapfile -t files < <(get_files "*.cdr")

	for (( i = 0; i < ${#files[@]}; i++ )); do
		if_cdr="${files[${i}]}"
		of_wav="${if_cdr%.*}.wav"

		declare args_ref
		declare -a args_ffmpeg args_sox

# Creates the command arguments for 'ffmpeg' and 'sox'.
		args_ffmpeg=(-ar 44.1k -ac 2)
		args_ffmpeg=(ffmpeg -f s16le "${args_ffmpeg[@]}" -i \""${if_cdr}"\" -c:a pcm_s16le "${args_ffmpeg[@]}" \""${of_wav}"\")

		args_sox=(sox -L \""${if_cdr}"\" \""${of_wav}"\")

# Depending on what the mode is, run 'ffmpeg' or 'sox' on the CDR file,
# specifying 'little-endian' for the input.
		args_ref="args_${mode}[@]"

		run_cmd "${!args_ref}"

# If 'cdr' is not among the chosen audio types, delete the CDR file.
		if [[ -z ${audio_types_run[cdr]} ]]; then
			rm "$if_cdr" || exit
		fi

		unset -v args_ref args_ffmpeg args_sox
	done

# Creates a file list to be used later in the 'create_cue' function.
	mapfile -t files_wav < <(get_files "*.bin" "*.wav")
}

# Creates a function, called 'encode_audio', which will encode the WAVs
# created by previously run functions.
encode_audio () {
	declare type_tmp
	declare -a files

	type_tmp="${audio_types[${type}]}"

	mapfile -t files < <(get_files "*.wav")

# If type is not 'wav' or there's no WAV files, return from this
# function. This makes it possible for the script to finish normally,
# even if there's no audio tracks.
	if [[ $type_tmp != 'wav' || ${#files[@]} -eq 0 ]]; then
		return
	fi

	case "$type" in
		'ogg')
			oggenc --quality=10 "${files[@]}" || exit
		;;
		'flac')
			flac -8 "${files[@]}" || exit
		;;
	esac
}

# Creates a function, called 'create_cue', which will create a new CUE
# sheet, based on the file lists created by the 'copy_all_tracks' and
# 'cdr2wav' functions.
create_cue () {
	declare index_string elements line_ref type_tmp
	declare -a offset
	declare -A ext_format

	index_string='INDEX 01 00:00:00'

	offset=('  ' '    ')
	ext_format=([bin]='BINARY' [cdr]='BINARY' [ogg]='OGG' [flac]='FLAC')

	type_tmp="${audio_types[${type}]}"

# Creates a function, called 'set_track_info', which will add FILE,
# TRACK, PREGAP, INDEX and POSTGAP commands. Pregap and postgap is only
# added if they exist in the source CUE sheet.
	set_track_info () {
		declare mode_ref format_ref track_string
		declare pregap_ref postgap_ref time_tmp

		mode_ref="if_cue[${track_n},track_mode]"
		format_ref="ext_format[${ext}]"

		track_string=$(printf 'TRACK %02d %s' "$track_n" "${!mode_ref}")

		eval of_cue_"${type}"+=\(\""FILE \\\"${fn}.${ext}\\\" ${!format_ref}"\"\)
		eval of_cue_"${type}"+=\(\""${offset[0]}${track_string}"\"\)

		pregap_ref="gaps[${track_n},pre]"
		postgap_ref="gaps[${track_n},post]"

		if [[ ${!pregap_ref} -gt 0 ]]; then
			time_tmp=$(time_convert "${!pregap_ref}")
			eval of_cue_"${type}"+=\(\""${offset[1]}PREGAP ${time_tmp}"\"\)
		fi

		eval of_cue_"${type}"+=\(\""${offset[1]}${index_string}"\"\)

		if [[ ${!postgap_ref} -gt 0 ]]; then
			time_tmp=$(time_convert "${!postgap_ref}")
			eval of_cue_"${type}"+=\(\""${offset[1]}POSTGAP ${time_tmp}"\"\)
		fi
	}

# Goes through the list of files produced by previously run functions,
# and creates a new CUE sheet based on that.
	for (( i = 0; i < ${#tracks_total[@]}; i++ )); do
		line_ref="files_${type_tmp}[${i}]"
		track_n="${tracks_total[${i}]}"

		declare fn ext

# Separates file name and extension.
		if [[ ! ${!line_ref} =~ ${regex[fn]} ]]; then
			continue
		fi

		fn="${BASH_REMATCH[1]}"
		ext="${BASH_REMATCH[2]}"

# If the extension is 'wav', then the correct extension is the same as
# the current audio type.
		if [[ $ext == 'wav' ]]; then
			ext="$type"
		fi

# Sets all the relevant file / track information.
		set_track_info

		unset -v fn ext
	done
}

# Creates a function, called 'clean_up', which deletes temporary files:
# * Potential WAV files
clean_up () {
	declare -a files

	mapfile -t files < <(get_files "*.wav")

	for (( i = 0; i < ${#files[@]}; i++ )); do
		fn="${files[${i}]}"
		rm "$fn" || exit
	done
}

# Checks if 'oggenc', 'flac' are installed. Depending on which mode is
# set, check if 'ffmpeg' or 'sox' is installed.
check_cmd 'oggenc' 'flac' "$mode"

# Creates the output directory and changes into it.
mkdir "$of_dn" || exit
cd "$of_dn" || exit

# Runs the functions.
read_cue
loop_set

copy_all_tracks

for type in "${!audio_types_run[@]}"; do
	cdr2wav
	encode_audio
	create_cue
done

# Prints the created CUE sheet to the terminal, and to the output file.
for type in "${!audio_types_run[@]}"; do
	of_cue="${of_dn}/${of_name}01_${type}.cue"
	lines_ref="of_cue_${type}[@]"

	printf '\n'
	printf '%s\r\n' "${!lines_ref}" | tee "$of_cue"
done

printf '\n'

# Deletes temporary files.
clean_up
