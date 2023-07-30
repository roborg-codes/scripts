#!/usr/bin/perl

# This script will round all the centiseconds in an SRT subtitle file.
# Every start time and end time of a subtitle will now end in ,?00

# Example: 00:20:47,500 --> 00:20:52,600
# Instead of: 00:20:47,457 --> 00:20:52,611

# This makes it a lot easier to edit the subtitle in for example Gnome
# Subtitles, if needed. Even if you're not going to edit the subtitle
# afterwards, it just looks better using whole centiseconds. The output
# filename is the same as the input filename, only a random number is
# added to the name. The start and end times of every subtitle line are
# adjusted so they don't overlap. They will all differ by at least 1
# centisecond.

use 5.34.0;
use strict;
use warnings;
use diagnostics;
use File::Basename qw(basename);
use Cwd qw(abs_path cwd);
use Encode qw(encode decode find_encoding);
use POSIX qw(floor);

my(%regex, @files, @format, $delim);

$regex{fn} = qr/^(.*)\.([^.]*)$/;
$regex{charset1} = qr/([^; ]+)$/;
$regex{charset2} = qr/^charset=(.*)$/;
$regex{newline} = qr/(\r){0,}(\n){0,}$/;
$regex{blank1} = qr/^[[:blank:]]*(.*)[[:blank:]]*$/;
$regex{blank2} = qr/^[[:blank:]]*$/;
$regex{blank3} = qr/[[:blank:]]+/;
$regex{last2} = qr/([0-9]{1,2})$/;
$regex{zero} = qr/^0+([0-9]+)$/;

if (! scalar(@ARGV)) { usage(); }

while (my $arg = shift(@ARGV)) {
	my($fn, $ext);

	if (length($arg)) {
		$fn = abs_path($arg);
		$fn =~ m/$regex{fn}/;
		$ext = lc($2);
	}

	if (! -f $fn or $ext ne 'srt') { usage(); }

	push(@files, $fn);
}

$delim = ' --> ';

$format[0] = qr/[0-9]+/;
$format[1] = qr/([0-9]{2}):([0-9]{2}):([0-9]{2}),([0-9]{3})/;
$format[2] = qr/[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}/;
$format[3] = qr/^($format[2])$delim($format[2])$/;

# The 'usage' subroutine prints syntax, and then quits.
sub usage {
	say "\n" . 'Usage: ' . basename($0) . ' [srt...]' . "\n";
	exit;
}

# The 'read_decode_fn' subroutine reads a text file and encodes the
# output to UTF-8.
sub read_decode_fn {
	my $fn = shift;
	my($file_enc, $tmp_enc, $enc, @lines);

	open(my $info, '-|', 'file', '-bi', $fn) or die "Can't run file: $!";
	chomp($file_enc = <$info>);
	close($info) or die "Can't close file: $!";

	$file_enc =~ m/$regex{charset1}/;
	$file_enc = $1;
	$file_enc =~ m/$regex{charset2}/;
	$file_enc = $1;

	$tmp_enc = find_encoding($file_enc);

	if (length($tmp_enc)) { $enc = $tmp_enc->name; }

	open(my $text, '< :raw', $fn) or die "Can't open file '$fn': $!";
	foreach my $line (<$text>) {
		if (length($enc)) {
			$line = decode($enc, $line);
			$line = encode('utf8', $line);
		}

		$line =~ s/$regex{newline}//g;

		$line =~ s/$regex{blank1}/$1/;
		$line =~ s/$regex{blank2}//;
		$line =~ s/$regex{blank3}/ /g;

		push(@lines, $line);
	}
	close $text or die "Can't close file '$fn': $!";

	return(@lines);
}

# The 'time_convert' subroutine converts the 'time line' back and forth
# between the time (hh:mm:ss) format and centiseconds.
sub time_convert {
	my $time = shift;

	my $h = 0;
	my $m = 0;
	my $s = 0;
	my $cs = 0;

	my $cs_last = 0;

# If argument is in the hh:mm:ss format...
	if ($time =~ m/$format[1]/) {
		$h = $1;
		$m = $2;
		$s = $3;
		$cs = $4;

		$h =~ s/$regex{zero}/$1/;
		$m =~ s/$regex{zero}/$1/;
		$s =~ s/$regex{zero}/$1/;
		$cs =~ s/$regex{zero}/$1/;

# Converts all the numbers to centiseconds, because those kind of values
# will be easier to compare in the 'time_calc' subroutine.
		$h = $h * 60 * 60 * 1000;
		$m = $m * 60 * 1000;
		$s = $s * 1000;

# Saves the last 2 (or 1) digits of $cs in $cs_last.
		if ($cs =~ m/$regex{last2}/) {
			$cs_last = $1;
			$cs_last =~ s/$regex{zero}/$1/;
		}

# If $cs_last is greater than 50, round it up, and if not, round it down.
		if ($cs_last >= 50) { $cs = ($cs - $cs_last) + 100; }
		else { $cs = $cs - $cs_last; }

		$time = $h + $m + $s + $cs;

# If argument is in the centisecond format...
	} elsif ($time =~ m/$format[0]/) {
		$cs = $time;

		$s = floor($cs / 1000);
		$m = floor($s / 60);
		$h = floor($m / 60);

		$cs = floor($cs % 1000);
		$s = floor($s % 60);
		$m = floor($m % 60);

		$time = sprintf('%02d:%02d:%02d,%03d', $h, $m, $s, $cs);
	}

	return($time);
}

# The 'time_calc' subroutine makes sure the current 'time line' is at
# least 1 centisecond greater than previous 'time line'. It also makes
# sure each line has a length of at least 1 centisecond.
sub time_calc {
	my $start_time = shift;
	my $stop_time = shift;
	my $previous = shift;

# If the previous 'time line' is greater than the current one, make the
# current 'time line' 1 centisecond greater than that.
	if (length($previous)) {
		if ($previous > $start_time) {
			$start_time = $previous + 100;
		}
	}

# If the stop time of the current 'time line' is less than the start
# time, then set it to the start time plus 1 centisecond.
	if ($stop_time < $start_time) {
		$stop_time = $start_time + 100;
	}

	return($start_time, $stop_time);
}

# The 'parse_srt' subroutine reads the SRT subtitle file passed to it,
# and adjusts the timestamps.
sub parse_srt {
	my $fn = shift;

	my($this, $next, $end, $total_n);
	my($start_time, $stop_time, $time_line, $previous);
	my(%lines, @lines_tmp);

	my $i = 0;
	my $j = 0;
	my $n = 0;
	my $switch = 0;

	push(@lines_tmp, read_decode_fn($fn));

	$end = $#lines_tmp;

	until ($i > $end) {
		$j = $i + 1;

		$this = $lines_tmp[$i];
		$next = $lines_tmp[$j];

		if (length($this) and $this =~ m/$format[0]/) {
			if (length($next) and $next =~ m/$format[3]/) {
				$start_time = $1;
				$stop_time = $2;

				$start_time = time_convert($start_time);
				$stop_time = time_convert($stop_time);

				($start_time, $stop_time) = time_calc($start_time, $stop_time, $previous);

				$previous = $stop_time;

				$start_time = time_convert($start_time);
				$stop_time = time_convert($stop_time);

				$time_line = $start_time . $delim . $stop_time;

				$n = $n + 1;

				$lines{$n}{time} = $time_line;

				$i = $i + 2;
				$j = $i + 1;

				$this = $lines_tmp[$i];
				$next = $lines_tmp[$j];

				if (length($this)) {
					push(@{$lines{$n}{text}}, $this);
				}

				until ($i > $end) {
					$i = $i + 1;
					$j = $i + 1;

					$this = $lines_tmp[$i];
					$next = $lines_tmp[$j];

					if (length($this) and $this =~ m/$format[0]/) {
						if (length($next) and $next =~ m/$format[3]/) {
							$switch = 1;
							last;
						}
					}

					if (length($this)) {
						push(@{$lines{$n}{text}}, $this);
					}
				}
			}
		}

		if ($switch eq 0) { $i = $i + 1; }
		else { $switch = 0; }
	}

	$total_n = $n;
	$n = 1;

	@lines_tmp = ();

	until ($n > $total_n) {
		push(@lines_tmp, $n);
		push(@lines_tmp, $lines{$n}{time});

		foreach my $line (@{$lines{$n}{text}}) {
			push(@lines_tmp, $line);
		}

		push(@lines_tmp, '');

		$n = $n + 1;
	}

	return(@lines_tmp);
}

while (my $fn = shift(@files)) {
	my $of = $fn;
	$of =~ s/$regex{fn}/$1/;
	$of = $of . '-' . int(rand(10000)) . '-' . int(rand(10000)) . '.srt';

	my(@lines);

	push(@lines, parse_srt($fn));

	open(my $srt, '> :raw', $of) or die "Can't open file '$of': $!";
	foreach my $line (@lines) {
		print $srt $line . "\r\n";
	}
	close($srt) or die "Can't close file '$of': $!";

	undef(@lines);

	say "\n" . 'Wrote file: ' . $of . "\n";
}
