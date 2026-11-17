#!/usr/bin/perl
# make_recording.pl - turn a real tab recording plus an input-event log into
# captioned evidence: evidence.mp4, evidence.gif, step stills, contact sheet,
# evidence.srt and evidence.md. Captions overlay the page bottom transparently,
# so the page keeps its exact size and the footer stays visible. The cursor and
# highlight boxes are drawn from the input coordinates in the event log; the
# page content and typing are the recording itself.
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname basename);
use File::Spec;
use File::Temp qw(tempdir);

my @clips;            # each: { video =>, events => }
my $out        = 'evidence/out';
my $fps        = 30;
my $gifFps     = 10;
my $gifW       = 900;
my $maxGifSec  = 25;
my $noGif      = 0;
my $noSheet    = 0;
my $crf        = 23;
my $speed      = 1;
my $gap        = 1.2;    # dead air longer than this is jump-cut down to it
my $cursorSize = 1;
my $font       = $ENV{EVIDENCE_FONT} || '';
my $selfcheck  = 0;
my $help       = 0;
my $voiceover  = undef;    # undef = off; '' or 'auto' = from captions; else a script file
my $voice      = 'F2';
my $voiceSpeed = 1.0;
my $vocoderDir = $ENV{TINY_VOCA_DIR} || '';
my $ttsPython  = '';

GetOptions(
    'clip=s@'      => \@clips,
    'out=s'        => \$out,
    'fps=i'        => \$fps,
    'gif-fps=i'    => \$gifFps,
    'gif-width=i'  => \$gifW,
    'max-gif=i'    => \$maxGifSec,
    'no-gif'       => \$noGif,
    'no-sheet'     => \$noSheet,
    'crf=i'        => \$crf,
    'speed=f'      => \$speed,
    'gap=f'        => \$gap,
    'cursor-size=f' => \$cursorSize,
    'font=s'       => \$font,
    'voiceover:s'  => \$voiceover,
    'voice=s'      => \$voice,
    'voice-speed=f' => \$voiceSpeed,
    'vocoder-dir=s' => \$vocoderDir,
    'tts-python=s'  => \$ttsPython,
    'selfcheck'    => \$selfcheck,
    'help'         => \$help,
) or die usage();

die usage() if $help;
die "need at least one --clip video.webm,events.json\n" . usage() unless @clips;
die "--speed must be > 0\n" unless $speed > 0;
die "--gap must be >= 0\n" unless $gap >= 0;

my $K = 1 / $speed;    # timestamp stretch factor

# ---------- ffmpeg ----------

sub find_ffmpeg {
    return $ENV{FFMPEG} if $ENV{FFMPEG} && -x $ENV{FFMPEG};
    my $onpath = `command -v ffmpeg 2>/dev/null`;
    chomp $onpath;
    return $onpath if $onpath && -x $onpath;
    my $cache = $ENV{EVIDENCE_TOOL_CACHE} || (($ENV{HOME} || "") . "/.cache/openbot-evidence");
    my $cached = "$cache/ffmpeg";
    return $cached if -x $cached;
    return '';
}

sub bootstrap_ffmpeg {
    my ($uname) = `uname -s` =~ /(\S+)/;
    my ($mach)  = `uname -m` =~ /(\S+)/;
    die "no ffmpeg on PATH and none cached; install it (Debian/Ubuntu: apt install ffmpeg, macOS: brew install ffmpeg) or set FFMPEG=/path/to/ffmpeg\n"
        unless $uname && $uname =~ /Linux/;
    die "no ffmpeg on PATH and the one-time static download is Linux x86-64 only (this machine is " . ($mach || 'unknown') . "); install ffmpeg with your package manager or set FFMPEG=/path/to/ffmpeg\n"
        unless $mach && $mach =~ /^(x86_64|amd64)$/;
    my $dir = $ENV{EVIDENCE_TOOL_CACHE} || (($ENV{HOME} || "") . "/.cache/openbot-evidence");
    make_path($dir);
    my $dest = "$dir/ffmpeg";
    my $url = 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz';
    print STDERR "no ffmpeg found - downloading a static build once into $dir (~80 MB)\n";
    my $tmp = tempdir(CLEANUP => 1);
    my $tarball = "$tmp/ffmpeg.tar.xz";
    my $dl = `command -v curl >/dev/null 2>&1 && echo curl || (command -v wget >/dev/null 2>&1 && echo wget)`;
    chomp $dl;
    die "need curl or wget to download ffmpeg\n" unless $dl;
    my $rc = $dl eq 'curl'
        ? system('curl', '-fsSL', '-o', $tarball, $url)
        : system('wget', '-q', '-O', $tarball, $url);
    die "ffmpeg download failed\n" if $rc != 0;
    system('tar', '-xJf', $tarball, '-C', $tmp) == 0
        or die "could not unpack the ffmpeg archive\n";
    my ($found) = glob("$tmp/ffmpeg-*-static/ffmpeg");
    die "unexpected ffmpeg archive layout\n" unless $found && -f $found;
    require File::Copy;
    File::Copy::copy($found, $dest) or die "could not install ffmpeg to $dest: $!\n";
    chmod 0755, $dest;
    return $dest;
}

my $FF = find_ffmpeg();
$FF = bootstrap_ffmpeg() unless $FF;
die "ffmpeg is not runnable at $FF\n" unless -x $FF;

sub qquote { my $s = shift; $s =~ s/'/'"'"'/g; return "'$s'"; }

sub run_cap {
    my @a = @_;
    my $cmd = join(' ', map { qquote($_) } @a) . ' 2>&1';
    my $o = `$cmd`;
    return ($? >> 8, $o);
}

sub run_or_die {
    my ($what, @a) = @_;
    my $rc = system(@a);
    die "$what failed (exit " . ($rc >> 8) . ")\n" if $rc != 0;
}

# ---------- probe ----------

sub probe_video {
    my $file = shift;
    my (undef, $info) = run_cap($FF, '-hide_banner', '-i', $file);
    my ($w, $h) = $info =~ /Video:.*?(\d{2,5})x(\d{2,5})/;
    die "cannot read the video size of $file\n" unless $w && $h;
    my $dur;
    if ($info =~ /Duration:\s*(\d+):(\d+):(\d+\.\d+)/) {
        $dur = $1 * 3600 + $2 * 60 + $3;
    } else {
        # webm from the tab recorder has no duration header: count sampled frames
        my $bytes = `$FF -hide_banner -loglevel error -fflags +genpts -i '$file' -vf fps=5,scale=1:1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null | wc -c`;
        chomp $bytes;
        $dur = $bytes / 3 / 5;
    }
    die "cannot read the video duration of $file\n" unless $dur && $dur > 0.2;
    return { w => $w, h => $h, dur => $dur };
}

# First and last frame of the magenta sync flash, in seconds. The start is
# what anchors the event log's wall-clock times onto the video timeline; the
# end is where the output cut begins, so the evidence never opens on the flash.
sub find_flash {
    my ($file, $dur) = @_;
    my $scan = $dur < 60 ? $dur : 60;
    my $raw = `$FF -hide_banner -loglevel error -fflags +genpts -i '$file' -t $scan -vf fps=30,scale=1:1 -f rawvideo -pix_fmt rgb24 - 2>/dev/null | od -An -tu1 -v`;
    my @b = split ' ', $raw;
    my ($first, $last);
    for (my $i = 0; $i * 3 + 2 < @b; $i++) {
        my ($r, $g, $bl) = @b[$i * 3, $i * 3 + 1, $i * 3 + 2];
        my $m = $r >= 150 && $bl >= 150 && $g <= 110;
        if ($m) { $first //= $i; $last = $i; }
        elsif (defined $first) { last; }
    }
    return undef unless defined $first;
    my $start = $first / 30;
    my $end   = (defined $last ? $last + 1 : $first + 8) / 30;
    $end = $start + 2 if $end - $start > 2;    # a runaway flash caps at 2 s
    return ($start, $end);
}

# ---------- events ----------

my @KIND = qw(sync move click type hl step);

sub read_events {
    my $file = shift;
    open my $fh, '<', $file or die "cannot open event log $file: $!\n";
    my @ev;
    my $n = 0;
    my $first = '';
    # peek: a JSON array as returned by run_script, or one TSV row per line
    while (my $line = <$fh>) {
        next if $line =~ /^\s*$/;
        $first = $line;
        last;
    }
    seek($fh, 0, 0);

    if ($first =~ /^\s*\[/) {
        local $/;
        my $raw = <$fh>;
        close $fh;
        require JSON::PP;
        my $rows = eval { JSON::PP->new->decode($raw) };
        die "the event log $file is not valid JSON: $@\n" unless ref $rows eq 'ARRAY';
        for my $r (@$rows) {
            next unless ref $r eq 'HASH';
            my $kind = $r->{kind} // '';
            next unless grep { $_ eq $kind } @KIND;
            my %e = %$r;
            $e{wall} = ($r->{ms} // $r->{wall} // 0) + 0;
            $e{line} = ++$n;
            push @ev, \%e;
        }
        die "no usable events in $file\n" unless @ev;
        return [ sort { $a->{wall} <=> $b->{wall} || $a->{line} <=> $b->{line} } @ev ];
    }

    while (my $line = <$fh>) {
        $line =~ s/\r?\n\z//;
        next unless length $line;
        next if $line =~ /^\s*#/;
        my @f = split /\t/, $line, -1;
        $n++;
        my $kind = $f[0] // '';
        next unless grep { $_ eq $kind } @KIND;
        my %e = (kind => $kind, wall => ($f[1] // '') + 0);
        if ($kind eq 'sync') {
        } elsif ($kind eq 'move') {
            @e{qw(x y)} = (($f[2] // '') + 0, ($f[3] // '') + 0);
        } elsif ($kind eq 'click') {
            @e{qw(x y l t w h)} = map { ($f[$_] // 0) + 0 } 2 .. 7;
            $e{label} = $f[8] // '';
        } elsif ($kind eq 'type') {
            $e{ch} = defined $f[2] ? $f[2] : '';
            @e{qw(l t w h)} = map { ($f[$_] // 0) + 0 } 3 .. 6;
        } elsif ($kind eq 'hl') {
            @e{qw(l t w h)} = map { ($f[$_] // 0) + 0 } 2 .. 5;
            $e{label} = $f[6] // '';
        } elsif ($kind eq 'step') {
            $e{status} = uc($f[2] // 'PASS');
            $e{text}   = $f[3] // '';
            $e{status} = 'PASS' unless $e{status} =~ /^(PASS|FAIL|SKIP)$/;
        }
        $e{line} = $n;
        push @ev, \%e;
    }
    close $fh;
    die "no events in $file\n" unless @ev;
    @ev = sort { $a->{wall} <=> $b->{wall} || $a->{line} <=> $b->{line} } @ev;
    return \@ev;
}

# ---------- ass ----------

sub tstr {
    my $t = shift;
    $t = 0 if !defined $t || $t < 0;
    my $cs = int($t * 100 + 0.5);
    my $h  = int($cs / 360000); $cs %= 360000;
    my $m  = int($cs / 6000);   $cs %= 6000;
    my $s  = int($cs / 100);    $cs %= 100;
    return sprintf('%d:%02d:%02d.%02d', $h, $m, $s, $cs);
}

sub col {    # #rrggbb -> &H00BBGGRR&
    my $hex = shift;
    $hex =~ s/^#//;
    my ($r, $g, $b) = map { hex } $hex =~ /(..)(..)(..)/;
    return sprintf('&H00%02X%02X%02X&', $b, $g, $r);
}

sub ass_head {
    my ($W, $H) = @_;
    my $fontname = $font ? $font : 'DejaVu Sans';
    return <<"ASS";
[Script Info]
ScriptType: v4.00+
PlayResX: $W
PlayResY: $H
WrapStyle: 2
ScaledBorderAndShadow: yes
YCbCr Matrix: TV.601

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Cur,$fontname,10,&H00FFFFFF,&H000000FF,&H00101010,&HC0000000,1,0,0,0,100,100,0,0,1,2.2,1.4,7,0,0,0,1
Style: Box,$fontname,10,&H00000000,&H000000FF,&H0000FFFF,&H00000000,0,0,0,0,100,100,0,0,1,3,0,7,0,0,0,1
Style: Ring,$fontname,10,&H000000FF,&H000000FF,&H00FFFFFF,&H000000FF,0,0,0,0,100,100,0,0,1,2.5,0,7,0,0,0,1
Style: Cap,$fontname,25,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,26,26,15,1
Style: Meta,$fontname,15,&H00C8D0DA,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,0,0,1,20,20,12,1
Style: MetaR,$fontname,15,&H00C8D0DA,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,0,0,3,20,20,12,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
ASS
}

my %STATUS_COL = (
    PASS => '#4ade80',
    FAIL => '#f87171',
    SKIP => '#9aa4b2',
);

# ---------- per-clip render ----------

sub build_clip {
    my ($idx, $clip, $W, $H, $padded, $outdir, $segfile) = @_;

    my $events = read_events($clip->{events});

    my ($vpts) = map { $_->{kind} eq 'sync' ? $_->{wall} : () } @$events;
    die "clip " . ($idx + 1) . ": the event log has no sync row - the flash is what "
      . "aligns captions to the video, so a run without it cannot be timed\n"
      unless defined $vpts;

    my ($flash_pts, $flash_end) = find_flash($clip->{video}, $clip->{dur});
    die "clip " . ($idx + 1) . ": could not find the magenta sync flash in the video. "
      . "The flash must be on screen for ~200 ms after recording starts; if the "
      . "recorder dropped it, re-record with the flash held longer.\n"
      unless defined $flash_pts;

    # the output opens right after the flash: never on magenta, never on the
    # unpainted frames some recorders emit before it
    my $t_start = $flash_end;

    # original-timeline position of a wall-clock event time
    my $ot = sub {
        my $wall = shift;
        return ($wall - $vpts) / 1000 + $flash_pts;
    };

    my @steps = grep { $_->{kind} eq 'step' } @$events;
    my $last_wall = $vpts;
    for my $e (@$events) { $last_wall = $e->{wall} if $e->{wall} > $last_wall; }

    my $tail = $last_wall > ($steps[-1]->{wall} // $vpts) ? 1.2 : 2.6;
    my $v_end = $ot->($last_wall) + $tail;
    $v_end = $clip->{dur} if $v_end > $clip->{dur};

    # jump-cut dead air: a gap between events longer than $gap keeps only $gap
    # seconds (split half after the earlier event, half before the later one),
    # and every cut is subtracted from the output clock so captions, cursor
    # and highlights stay on their frames
    my @times = sort { $a <=> $b } grep { $_ >= $t_start && $_ <= $v_end }
        map { $ot->($_->{wall}) } @$events;
    my (@segs, @cuts);
    if ($gap > 0 && @times > 1) {
        my $s = $times[0] - $gap / 2;
        $s = $t_start if $s < $t_start;
        my $prev = $times[0];
        for my $i (1 .. $#times) {
            my $b = $times[$i];
            if ($b - $prev > $gap) {
                my $e = $prev + $gap / 2;
                push @segs, [$s, $e];
                push @cuts, [$e, $b - $gap / 2];
                $s = $b - $gap / 2;
            }
            $prev = $b;
        }
        push @segs, [$s, $v_end];
    } else {
        @segs = ([$t_start, $v_end]);
    }

    my $removed = sub {
        my $x = shift;
        my $r = 0;
        for my $c (@cuts) {
            last if $c->[0] >= $x;
            my $o = ($c->[1] > $x ? $x : $c->[1]) - $c->[0];
            $r += $o if $o > 0;
        }
        return $r;
    };

    my $vt = sub {
        my $wall = shift;
        my $x = $ot->($wall);
        return ($x - $t_start - $removed->($x)) * $K;
    };
    my $dur_out = ($v_end - $t_start - $removed->($v_end)) * $K;
    die "clip " . ($idx + 1) . ": nothing to render, the recording is too short\n"
      if $dur_out < 0.5;

    my @ass = (ass_head($W, $H));

    # ---- cursor track: from real pointer coordinates ----
    my @track;
    for my $e (@$events) {
        next unless $e->{kind} =~ /^(move|click)$/;
        next unless defined $e->{x};
        push @track, [ $vt->($e->{wall}), $e->{x}, $e->{y}, $e->{kind} ];
    }
    if (@track > 700) {    # keep the shape of the path, drop the fine detail
        my $step = int(@track / 700) + 1;
        my @thin;
        for (my $i = 0; $i < @track; $i++) {
            push @thin, $track[$i] if $i % $step == 0 || $track[$i][3] eq 'click';
        }
        @track = @thin;
    }

    my $csz = $cursorSize;
    my $ARROW = 'm 0 0 l 0 19 l 4.4 14.9 l 7.4 21.6 l 10.4 20.2 l 7.4 13.7 l 13 13.7';
    my $cur = sub {
        my ($x, $y) = @_;
        return sprintf(
            '{\an7\pos(%d,%d)\p1\fscx%.0f\fscy%.0f\bord2.2\shad1.4\1c&HFFFFFF&\3c&H101010&}%s{\p0}',
            $x, $y, 100 * $csz, 100 * $csz, $ARROW
        );
    };

    if (@track) {
        my $first = $track[0];
        push @ass, sprintf('Dialogue: 5,%s,%s,Cur,,0,0,0,,{\an7\pos(%d,%d)\fad(140,0)\p1\fscx%.0f\fscy%.0f\bord2.2\shad1.4\1c&HFFFFFF&\3c&H101010&}%s{\p0}',
            tstr(0), tstr($first->[0]), $first->[1], $first->[2], 100 * $csz, 100 * $csz, $ARROW)
            if $first->[0] > 0.02;
    }
    for (my $i = 0; $i < @track; $i++) {
        my $a = $track[$i];
        my $b = $track[$i + 1];
        my $t1 = $a->[0];
        my $t2 = $b ? $b->[0] : ($dur_out + 0.1);
        next if $t2 <= $t1;
        if ($b && ($t2 - $t1) <= 1.4 && ($a->[1] != $b->[1] || $a->[2] != $b->[2])) {
            push @ass, sprintf(
                'Dialogue: 5,%s,%s,Cur,,0,0,0,,{\an7\move(%d,%d,%d,%d,0,%d)\p1\fscx%.0f\fscy%.0f\bord2.2\shad1.4\1c&HFFFFFF&\3c&H101010&}%s{\p0}',
                tstr($t1), tstr($t2), $a->[1], $a->[2], $b->[1], $b->[2],
                int(($t2 - $t1) * 1000), 100 * $csz, 100 * $csz, $ARROW
            );
        } else {
            push @ass, sprintf('Dialogue: 5,%s,%s,Cur,,0,0,0,,%s', tstr($t1), tstr($t2), $cur->($a->[1], $a->[2]));
        }
    }

    # ---- highlight boxes: clicks, typing runs, explicit markers ----
    my $box = sub {
        my ($t1, $t2, $l, $t, $w, $h, $colour) = @_;
        $colour = '#f4b942' unless defined $colour;
        $w = 6 if $w < 6;
        $h = 6 if $h < 6;
        my $p = sprintf('m 0 0 l %d 0 l %d %d l 0 %d', $w, $w, $h, $h);
        # The drawing path must sit inside the same override block as \p1,
        # otherwise libass drops it. \1a&HFF& keeps the shape unfilled so the
        # box is an outline and never hides the control it points at.
        return sprintf(
            'Dialogue: 2,%s,%s,Box,,0,0,0,,{\an7\pos(%d,%d)\fad(90,140)\p1\bord4\1a&HFF&\3c%s\blur1}%s{\p0}',
            tstr($t1), tstr($t2), $l, $t, col($colour), $p
        );
    };

    for my $e (@$events) {
        if ($e->{kind} eq 'click' && $e->{w} > 0) {
            my $t1 = $vt->($e->{wall});
            push @ass, $box->($t1, $t1 + 1.5 * $K, $e->{l}, $e->{t}, $e->{w}, $e->{h});
            push @ass, sprintf(
                'Dialogue: 4,%s,%s,Ring,,0,0,0,,{\an7\pos(%d,%d)\fad(0,120)\t(0,%d,\fscx300\fscy300\1a&HFF&\3a&HFF&)\p1\bord3\3c&HFFFFFF&}m 0 -9 b 5 -9 9 -5 9 0 b 9 5 5 9 0 9 b -5 9 -9 5 -9 0 b -9 -5 -5 -9 0 -9{\p0}',
                tstr($t1), tstr($t1 + 0.5 * $K), $e->{x} // ($e->{l} + $e->{w} / 2),
                $e->{y} // ($e->{t} + $e->{h} / 2), int(450 * $K)
            );
        } elsif ($e->{kind} eq 'hl' && $e->{w} > 0) {
            my $t1 = $vt->($e->{wall});
            push @ass, $box->($t1, $t1 + 1.6 * $K, $e->{l}, $e->{t}, $e->{w}, $e->{h});
        }
    }

    # typing runs: one box per field, held while the characters land
    my @spans;
    for my $e (@$events) {
        next unless $e->{kind} eq 'type' && $e->{w} > 0;
        my $t = $vt->($e->{wall});
        my $key = join(',', @$e{qw(l t w h)});
        if (@spans && $spans[-1]{key} eq $key && $t - $spans[-1]{end} < 1.5 * $K) {
            $spans[-1]{end} = $t + 0.28 * $K;
        } else {
            push @spans, { key => $key, l => $e->{l}, t => $e->{t}, w => $e->{w}, h => $e->{h}, start => $t - 0.12 * $K, end => $t + 0.28 * $K };
        }
    }
    for my $s (@spans) {
        push @ass, $box->($s->{start}, $s->{end}, $s->{l}, $s->{t}, $s->{w}, $s->{h}, '#7cc4ff');
    }

    # ---- captions + status in the strip below the page ----
    my @caps;
    for (my $i = 0; $i < @steps; $i++) {
        my $t1 = $vt->($steps[$i]{wall});
        my $t2 = $i + 1 < @steps ? $vt->($steps[$i + 1]{wall}) : $dur_out;
        $t2 = $dur_out if $t2 > $dur_out;
        $t2 = $t1 + 0.8 if $t2 - $t1 < 0.8;
        $t2 = $dur_out if $t2 > $dur_out && $i == $#steps;
        next if $t2 <= $t1;
        push @caps, { start => $t1, end => $t2, text => $steps[$i]{text}, status => $steps[$i]{status}, n => $i + 1, total => scalar(@steps) };
    }

    # captions sit transparent over the page bottom, step meta on the top
    # edge, both outlined so they stay readable over any page color
    my $capfx  = '{\fad(120,120)\bord2.4\shad1.4\3c&H141414&}';
    my $metafx = '\bord1.6\shad1\3c&H141414&';
    my $metay  = 14;

    for my $c (@caps) {
        push @ass, sprintf(
            'Dialogue: 1,%s,%s,Cap,,0,0,0,,%s%s',
            tstr($c->{start}), tstr($c->{end}), $capfx,
            escape_ass($c->{text})
        );
        push @ass, sprintf(
            'Dialogue: 2,%s,%s,Meta,,0,0,0,,{\an1\pos(22,%d)%s}step %d of %d',
            tstr($c->{start}), tstr($c->{end}), $metay, $metafx, $c->{n}, $c->{total}
        );
        push @ass, sprintf(
            'Dialogue: 2,%s,%s,MetaR,,0,0,0,,{\an3\pos(%d,%d)%s\1c%s&}%s',
            tstr($c->{start}), tstr($c->{end}), $W - 22, $metay, $metafx,
            col($STATUS_COL{ $c->{status} }), $c->{status}
        );
    }
    my $assfile = "$outdir/clip" . ($idx + 1) . ".ass";
    open my $af, '>', $assfile or die "cannot write $assfile: $!\n";
    print $af join("\n", @ass), "\n";
    close $af;

    # ---- render ----
    my $fontsdir = '';
    if ($font && $font =~ m{/}) {
        (my $dir = $font) =~ s{/[^/]+$}{};
        $fontsdir = ':fontsdir=' . esc_filter($dir);
        $font =~ s{.*/}{};
        $font =~ s/\.\w+$//;
    }
    my $assf   = esc_filter($assfile);
    my $tailvf = sprintf('fps=%d,setpts=PTS*%.6f', $fps, $K);
    $tailvf .= ",pad=$W:$H:0:0" if $padded;
    my $assvf = sprintf('ass=%s%s', $assf, $fontsdir);

    if (@segs == 1) {
        my $chain = sprintf('trim=start=%.4f:end=%.4f,setpts=PTS-STARTPTS,%s,%s',
            $segs[0][0], $segs[0][1], $tailvf, $assvf);
        run_or_die("rendering clip " . ($idx + 1),
            $FF, '-hide_banner', '-loglevel', 'error', '-fflags', '+genpts',
            '-i', $clip->{video}, '-vf', $chain,
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', $crf,
            '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', '-y', $segfile);
    } else {
        my @lbl = map { "v$_" } 0 .. $#segs;
        my @fc = map {
            sprintf('[0:v]trim=start=%.4f:end=%.4f,setpts=PTS-STARTPTS[%s]',
                $segs[$_][0], $segs[$_][1], $lbl[$_])
        } 0 .. $#segs;
        push @fc, sprintf('%sconcat=n=%d:v=1:a=0[vcat]',
            join('', map { "[$_]" } @lbl), scalar(@segs));
        push @fc, sprintf('[vcat]%s,%s[vout]', $tailvf, $assvf);
        run_or_die("rendering clip " . ($idx + 1),
            $FF, '-hide_banner', '-loglevel', 'error', '-fflags', '+genpts',
            '-i', $clip->{video}, '-filter_complex', join(';', @fc), '-map', '[vout]',
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', $crf,
            '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', '-y', $segfile);
    }

    return { dur => $dur_out, caps => \@caps, steps => \@steps, seg => $segfile,
             W => $W, H => $H, vt => $vt, vh => $H, cuts => scalar @cuts };
}

sub escape_ass {
    my $s = shift;
    $s =~ s/\\/\\\\/g;
    $s =~ s/\{/\\{/g;
    $s =~ s/\}/\\}/g;
    $s =~ s/\n/\\N/g;
    return $s;
}

sub esc_filter {
    my $p = shift;
    $p =~ s/([\\':,\[\]])/\\$1/g;
    return $p;
}

sub usage {
    return <<'TXT';
usage: make_recording.pl --clip video.webm,events.json [--clip ...] --out DIR [options]

  --clip FILE,EVENTS   a recording and its event log; repeat for several clips
  --out DIR            output folder (default evidence/out)
  --speed F            play at F speed, e.g. 0.75 to slow for readability (default 1)
  --gap F              jump-cut dead air between events down to F seconds (default 1.2; 0 disables)
  --fps N              output frame rate (default 30)
  --crf N              x264 quality, lower is better (default 23)
  --cursor-size F      cursor scale (default 1)
  --gif-width N        gif width (default 900)
  --gif-fps N          gif frame rate (default 10)
  --max-gif N          longest gif in seconds (default 25)
  --no-gif, --no-sheet skip those outputs
  --voiceover[=auto|FILE]  also speak the steps over evidence.mp4 with
                           tiny-voca (default: each humanized caption's first
                           sentence; FILE lines map 1:1 to steps, # comments,
                           empty line = silence). Needs --vocoder-dir.
  --voice F2|M2      narration voice (default F2)
  --voice-speed F    narration rate (default 1)
  --vocoder-dir DIR  tiny-voca checkout holding model.onnx and phonemizer/
                     (default: TINY_VOCA_DIR)
  --tts-python PATH  python with onnxruntime, soundfile, dizione
                     (default: .venv/bin/python inside --vocoder-dir)
  --selfcheck          after the build, verify duration/stills/srt/gif and exit nonzero on a mismatch
  --font FILE          TTF to use for captions

Captions always overlay the page bottom transparently, so the page keeps its
exact size and the footer stays visible.
TXT
}

# ---------- gif ----------

sub make_gif {
    my ($mp4, $gif, $limit) = @_;
    my $chain = sprintf(
        'fps=%d,scale=%d:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3',
        $gifFps, $gifW
    );
    my @t = ('-t', $limit) if $limit;
    run_or_die('building the gif',
        $FF, '-hide_banner', '-loglevel', 'error', @t, '-i', $mp4,
        '-vf', $chain, '-loop', '0', '-y', $gif);
}

# ---------- stills, sheet, srt, md ----------

sub slugify {
    my $s = shift;
    $s = lc $s;
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/^-+|-+$//g;
    $s = substr($s, 0, 42);
    $s =~ s/-+$//;
    return length $s ? $s : 'step';
}

sub write_still {
    my ($mp4, $t, $file) = @_;
    run_or_die("extracting the still for $file",
        $FF, '-hide_banner', '-loglevel', 'error', '-ss', sprintf('%.3f', $t),
        '-i', $mp4, '-frames:v', '1', '-y', $file);
    if (!-s $file) {
        # -ss past the real stream end exits 0 with no output (computed
        # durations can overshoot the rendered file by a few frames)
        run_or_die("extracting the still for $file (retried earlier)",
            $FF, '-hide_banner', '-loglevel', 'error', '-ss', sprintf('%.3f', $t * 0.5),
            '-i', $mp4, '-frames:v', '1', '-y', $file);
    }
    die "could not extract a still at ${t}s of $mp4\n" unless -s $file;
}

sub make_sheet {
    my ($stills, $sheet, $dir) = @_;
    my $n = @$stills;
    return 0 unless $n;
    my $cols = $n <= 2 ? $n : $n <= 4 ? 2 : 3;
    my $rows = int(($n + $cols - 1) / $cols);
    my $slots = $cols * $rows;

    my $seq = "$dir/sheetseq";
    make_path($seq);
    remove_tree($seq) if -d $seq;
    make_path($seq);

    # scale every still to the same tile width so the grid lines up
    my $tw = $cols >= 3 ? 560 : 720;
    my @scaled;
    for (my $i = 0; $i < $n; $i++) {
        my $s = "$seq/src-$i.png";
        run_or_die('scaling a sheet tile',
            $FF, '-hide_banner', '-loglevel', 'error', '-i', $stills->[$i],
            '-vf', "scale=$tw:-2", '-y', $s);
        push @scaled, $s;
    }
    my ($tile_w, $tile_h) = (0, 0);
    {
        my (undef, $info) = run_cap($FF, '-hide_banner', '-i', $scaled[0]);
        ($tile_w, $tile_h) = $info =~ /(\d{2,5})x(\d{2,5})/;
    }
    die "cannot size the contact sheet tiles\n" unless $tile_w && $tile_h;

    my $blank = "$seq/blank.png";
    run_or_die('making the sheet filler',
        $FF, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
        '-i', "color=c=0x101418:s=${tile_w}x${tile_h}", '-frames:v', '1', '-y', $blank);

    for (my $i = 0; $i < $slots; $i++) {
        my $src = $i < $n ? $scaled[$i] : $blank;
        my $dst = sprintf('%s/%03d.png', $seq, $i + 1);
        require File::Copy;
        File::Copy::copy($src, $dst) or die "cannot stage sheet tile $dst: $!\n";
    }

    run_or_die('building the contact sheet',
        $FF, '-hide_banner', '-loglevel', 'error', '-framerate', '1',
        '-i', "$seq/%03d.png", '-vf', "tile=${cols}x${rows}:margin=8:padding=8:color=0x05070a",
        '-frames:v', '1', '-y', $sheet);
    remove_tree($seq);
    return 1;
}

sub srt_ts {
    my $t = shift;
    $t = 0 if $t < 0;
    my $ms = int($t * 1000 + 0.5);
    my $h = int($ms / 3600000); $ms %= 3600000;
    my $m = int($ms / 60000);   $ms %= 60000;
    my $s = int($ms / 1000);    $ms %= 1000;
    return sprintf('%02d:%02d:%02d,%03d', $h, $m, $s, $ms);
}

# ---------- voiceover ----------

# Caption text -> a line that is safe and natural to speak. Conservative on
# purpose: it defuses hostile tokens (urls, host:port, selectors, shorthand)
# and otherwise keeps the author's wording. Pass --voiceover=FILE when the
# spoken lines should differ from the captions.
sub humanize_caption {
    my $t = shift;
    $t =~ s/^\s+|\s+$//g;
    $t =~ s/[*`~]//g;    # markdown furniture
    $t =~ s{https?://\S+}{the linked page}gi;
    $t =~ s{\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?}{the local test server}gi;
    $t =~ s/\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b/the email address/gi;
    $t =~ s/\ba11y\b/accessibility/gi;
    $t =~ s/\bi18n\b/internationalization/gi;
    $t =~ s/\bl10n\b/localization/gi;
    $t =~ s/\bPASS\b/pass/g;
    $t =~ s/\bFAIL\b/fail/g;
    $t =~ s/\bSKIP\b/skipped/g;
    $t =~ s/\b([A-Za-z][\w-]*)=(\w+)\b/$1 is $2/g;    # aria-expanded=true
    $t =~ s/>=/ at least /g;
    $t =~ s/<=/ at most /g;
    $t =~ s/\s*->\s*/ to /g;
    $t =~ s/\bthe\s+#[A-Za-z][\w-]*/the element/g;    # the #id selector
    $t =~ s/#[A-Za-z][\w-]*/the element/g;            # remaining #id selectors
    $t =~ s/\s{2,}/ /g;
    $t =~ s/^\s+|\s+$//g;
    return $t;
}

# Auto narration: the caption's first sentence, capped near 100 chars at a
# word boundary, so a spoken line stays inside its own step's window.
sub auto_narration {
    my $t = humanize_caption(shift);
    if ($t =~ /^(.+?[.!?…])(?:\s|$)/) {
        $t = $1;
    } elsif (length($t) > 100) {
        $t = substr($t, 0, 100);
        $t =~ s/\s+\S*$//;
        $t .= '.';
    }
    return $t;
}

# PCM wav duration in seconds, from the RIFF header - no ffprobe needed.
sub wav_duration {
    my $f = shift;
    open my $fh, '<:raw', $f or return undef;
    read($fh, my $riff, 12) or return undef;
    return undef unless substr($riff, 0, 4) eq 'RIFF' && substr($riff, 8, 4) eq 'WAVE';
    my ($rate, $ch, $bits, $bytes);
    while (read($fh, my $hd, 8) == 8) {
        my ($id, $sz) = unpack('a4V', $hd);
        if ($id eq 'fmt ') {
            read($fh, my $fmt, $sz);
            my @f = unpack('vvVVvv', substr($fmt, 0, 16));
            ($ch, $rate, $bits) = ($f[1], $f[2], $f[5]);
            read($fh, my $pad, 1) if $sz % 2;
        } else {
            if ($id eq 'data') { $bytes = $sz; }
            my $skip = $sz + ($sz % 2);
            seek($fh, $skip, 1) or last;
        }
    }
    close $fh;
    return undef unless $rate && $ch && $bits && $bytes;
    return $bytes / ($rate * $ch * $bits / 8);
}

# Speak the steps over the mp4. Narration lines come from the captions
# (humanized) or from a script file whose non-# lines map 1:1 to the steps in
# order; empty lines leave their step silent. Lines are placed at their
# step's start and shifted right when a previous line still runs, so speech
# never overlaps. Video stream is copied, not re-encoded.
sub add_voiceover {
    my ($mp4, $caps, $total, $vo, $voice, $vspeed, $vdir, $py) = @_;

    my @say;
    if (!length($vo) or lc($vo) eq 'auto') {
        @say = map { auto_narration($_->{text}) } @$caps;
    } else {
        open my $fh, '<', $vo or die "cannot open voiceover script $vo: $!\n";
        my @lines;
        while (my $l = <$fh>) {
            $l =~ s/\r?\n\z//;
            next if $l =~ /^#/;
            push @lines, $l;
        }
        close $fh;
        @say = map { $_ < @lines ? $lines[$_] : '' } 0 .. $#$caps;
        print STDERR "voiceover script: " . scalar(@lines) . " lines for " . scalar(@$caps)
          . " steps - extra lines are ignored\n" if @lines > @$caps;
    }

    my ($model, $phones);
    if ($vdir) {
        for my $cand ("$vdir/model.onnx", "$vdir/onnx/model.onnx") {
            $model = $cand if -f $cand;
        }
        $phones = "$vdir/phonemizer" if -d "$vdir/phonemizer";
    }
    $model  ||= $ENV{TINY_VOCA_MODEL}  || '';
    $phones ||= $ENV{TINY_VOCA_PHONEMIZER} || '';
    die "voiceover needs the tiny-voca model: pass --vocoder-dir (a checkout holding model.onnx and phonemizer/) or set TINY_VOCA_MODEL and TINY_VOCA_PHONEMIZER\n"
        unless $model && -f $model;
    die "voiceover needs the dizione phonemizer data (a phonemizer/ dir next to the model)\n"
        unless $phones && -d $phones;
    $py = (-x "$vdir/.venv/bin/python" ? "$vdir/.venv/bin/python" : '') if !$py && $vdir;
    $py ||= 'python3';

    my $tts = File::Spec->rel2abs(File::Spec->catfile(dirname(__FILE__), 'tts_voiceover.py'));
    die "cannot find $tts\n" unless -f $tts;

    my (@job, @place);
    for my $i (0 .. $#$caps) {
        my $text = defined $say[$i] ? $say[$i] : '';
        $text =~ s/^\s+|\s+$//g;
        next unless length $text;
        die "voiceover: step " . ($i + 1) . " starts at " . sprintf('%.1f', $caps->[$i]{start})
          . "s, past the end of the $total-s video - nothing to speak\n"
            if $caps->[$i]{start} >= $total - 0.1;
        my $id = sprintf('vo-%02d', $i + 1);
        push @job, { id => $id, text => $text };
        push @place, { id => $id, start => $caps->[$i]{start}, step => $i + 1 };
    }
    die "voiceover: every narration line is empty, nothing to speak\n" unless @job;

    my $work = tempdir(CLEANUP => 1);
    my $jobfile = "$work/job.json";
    open my $jf, '>', $jobfile or die "cannot write $jobfile: $!\n";
    require JSON::PP;
    print $jf JSON::PP->new->encode(\@job);
    close $jf;

    print STDERR "voiceover: synthesizing " . scalar(@job) . " line(s) with tiny-voca ($voice, speed $vspeed)\n";
    run_or_die('synthesizing the voiceover',
        $py, $tts, '--job', $jobfile, '--workdir', $work,
        '--model', $model, '--phonemizer', $phones,
        '--voice', $voice, '--speed', $vspeed);

    my $shifted = 0;
    my $prev_end = 0;
    for my $p (@place) {
        my $d = wav_duration("$work/$p->{id}.wav");
        die "voiceover: no audio was synthesized for step $p->{step}\n" unless $d && $d > 0;
        my $start = $p->{start};
        if ($start < $prev_end + 0.12) {
            $start = $prev_end + 0.12;
            $shifted++;
        }
        # a line that would run past the video end moves earlier, so the
        # reviewer hears the whole sentence; it may butt-join or briefly
        # lap the previous line (the lap lands in inter-sentence silence,
        # which beats a mid-word cut); only with no room at all does it
        # stay put and get cut
        if ($start + $d > $total - 0.05) {
            my $earlier = $total - 0.05 - $d;
            if ($earlier >= $prev_end + 0.12) {
                print STDERR "voiceover: line for step $p->{step} moved earlier so it finishes inside the video\n";
                $start = $earlier;
            } elsif ($earlier >= $prev_end - 0.3) {
                print STDERR "voiceover: line for step $p->{step} moved earlier, lapping the previous line by "
                  . sprintf('%.2fs', $prev_end - $earlier) . " rather than losing its ending\n";
                $start = $earlier;
            } else {
                print STDERR "voiceover: warning - line for step $p->{step} cannot fit and is cut at the end of the video\n";
            }
        }
        $p->{delay} = int($start * 1000 + 0.5);
        $prev_end = $start + $d;
    }
    print STDERR "voiceover: $shifted line(s) shifted right so no speech overlaps\n" if $shifted;

    my @fc = ('anullsrc=r=24000:cl=mono[vbed]');
    my @mix = ('[vbed]');
    my @cmd = ($FF, '-hide_banner', '-loglevel', 'error', '-i', $mp4);
    for my $i (0 .. $#place) {
        my $lab = "vd$i";
        push @cmd, '-i', "$work/$place[$i]{id}.wav";
        push @fc, sprintf('[%d:a]adelay=%d[%s]', $i + 1, $place[$i]{delay}, $lab);
        push @mix, "[$lab]";
    }
    push @fc, join('', @mix) . sprintf('amix=inputs=%d:normalize=0:duration=longest[vmix]', scalar @mix);
    push @fc, sprintf('[vmix]atrim=0:%.3f,asetpts=PTS-STARTPTS[vaout]', $total);
    my $tmpvo = "$mp4.vo.mp4";
    run_or_die('adding the voiceover',
        @cmd, '-filter_complex', join(';', @fc),
        '-map', '0:v', '-map', '[vaout]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '96k',
        '-movflags', '+faststart', '-y', $tmpvo);
    rename $tmpvo, $mp4 or die "cannot replace $mp4 with the voiced version: $!\n";
    print STDERR "voiceover: audio muxed into $mp4 (the gif stays silent)\n";
}

# ---------- main ----------

my $dir = $out;
make_path($dir);
# segments are referenced from a concat list, so keep the paths absolute
{
    require Cwd;
    my $abs = Cwd::abs_path($dir);
    $dir = $abs if defined $abs;
}

my @parsed;
for my $spec (@clips) {
    my ($v, $e) = split /,/, $spec, 2;
    die "--clip needs video,events - got '$spec'\n" unless $v && $e;
    die "no such recording: $v\n" unless -f $v;
    die "no such event log: $e\n" unless -f $e;
    my $p = probe_video($v);
    push @parsed, { video => $v, events => $e, %$p };
}

# x264/yuv420p needs even dimensions; pad a pixel instead of failing the build
my $padded = 0;
for my $p (@parsed) {
    if ($p->{w} % 2 || $p->{h} % 2) {
        $p->{w} += $p->{w} % 2;
        $p->{h} += $p->{h} % 2;
        $padded = 1;
    }
}
my ($W, $H) = ($parsed[0]{w}, $parsed[0]{h});
for my $p (@parsed) {
    die "all clips must have the same viewport size ($W x $H vs $p->{w} x $p->{h})\n"
        unless $p->{w} == $W && $p->{h} == $H;
}

my (@segs, @allcaps, $total, $total_cuts);
for (my $i = 0; $i < @parsed; $i++) {
    my $seg = sprintf('%s/seg-%02d.mp4', $dir, $i + 1);
    my $info = build_clip($i, $parsed[$i], $W, $H, $padded, $dir, $seg);
    $info->{clip_no} = $i + 1;
    push @segs, { file => $seg, info => $info, offset => ($total // 0) };
    for my $c (@{ $info->{caps} }) {
        push @allcaps, { %$c, start => $c->{start} + ($total // 0), end => $c->{end} + ($total // 0), clip => $i + 1 };
    }
    $total = ($total // 0) + $info->{dur};
    $total_cuts += $info->{cuts};
}

my $mp4 = "$dir/evidence.mp4";
if (@segs == 1) {
    require File::Copy;
    File::Copy::copy($segs[0]{file}, $mp4) or die "cannot write $mp4: $!\n";
} else {
    my $list = "$dir/concat.txt";
    open my $lf, '>', $list or die "cannot write $list: $!\n";
    print $lf "file '" . $_->{file} . "'\n" for @segs;
    close $lf;
    run_or_die('joining the clips',
        $FF, '-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0',
        '-i', $list, '-c', 'copy', '-y', $mp4);
    unlink $list;
}

add_voiceover($mp4, \@allcaps, $total, $voiceover, $voice, $voiceSpeed, $vocoderDir, $ttsPython)
    if defined $voiceover;

# srt
my $srt = "$dir/evidence.srt";
open my $sf, '>', $srt or die "cannot write $srt: $!\n";
my $n = 0;
for my $c (@allcaps) {
    $n++;
    printf $sf "%d\n%s --> %s\n%s\n\n", $n, srt_ts($c->{start}), srt_ts($c->{end}), $c->{text};
}
close $sf;

# step stills - caption times here are already local to their own clip
my $stepsdir = "$dir/steps";
make_path($stepsdir);
my @stills;
for my $s (@segs) {
    my $caps = $s->{info}{caps};
    for my $c (@$caps) {
        my $file = "$stepsdir/" . sprintf('c%d-%02d-%s', $s->{info}{clip_no}, $c->{n}, slugify($c->{text})) . '.png';
        my $mid = ($c->{start} + $c->{end}) / 2;
        $mid = $s->{info}{dur} - 0.1 if $mid > $s->{info}{dur} - 0.1;
        $mid = $c->{start} + 0.2 if $mid < $c->{start};
        $mid = 0 if $mid < 0;
        write_still($s->{file}, $mid, $file);
        push @stills, $file;
    }
}

my $sheet = "$dir/evidence-sheet.png";
if (!$noSheet) {
    make_sheet(\@stills, $sheet, $dir) or print STDERR "no steps to sheet\n";
}

# gif
my $gif = "$dir/evidence.gif";
my $gif_made = 0;
unless ($noGif) {
    my $limit = $total > $maxGifSec ? $maxGifSec : undef;
    make_gif($mp4, $gif, $limit);
    $gif_made = 1;
}

# md
my $md = "$dir/evidence.md";
open my $mf, '>', $md or die "cannot write $md: $!\n";
print $mf "# Evidence\n\n";
printf $mf "**%d steps - %d PASS, %d FAIL, %d SKIP** (%.1fs)\n\n",
    scalar(@allcaps),
    scalar(grep { $_->{status} eq 'PASS' } @allcaps),
    scalar(grep { $_->{status} eq 'FAIL' } @allcaps),
    scalar(grep { $_->{status} eq 'SKIP' } @allcaps),
    $total;
printf $mf "Recording: %s\n\n", join(', ', map { basename($_->{video}) } @parsed);
print $mf "| clip | step | caption | status | time |\n|---|---|---|---|---|\n";
for my $c (@allcaps) {
    printf $mf "| %d | %d | %s | %s | %.1f-%.1fs |\n",
        $c->{clip}, $c->{n}, escape_md($c->{text}), $c->{status}, $c->{start}, $c->{end};
}
print $mf "\n";
for my $f (['evidence.mp4', 'full-length recording with cursor, highlights and captions'],
           ['evidence.gif', 'short looping preview'],
           ['evidence-sheet.png', 'every step at a glance'],
           ['steps/', 'one captioned still per step'],
           ['evidence.srt', 'captions as subtitles']) {
    printf $mf "- `%s/%s` - %s\n", $dir, $f->[0], $f->[1] if -e "$dir/$f->[0]";
}
close $mf;

sub escape_md { my $s = shift; $s =~ s/\|/\\|/g; return $s; }

# ---------- report ----------

my @missing;
push @missing, 'video' unless -s $mp4;
push @missing, 'contact sheet' unless $noSheet || -s $sheet;
push @missing, 'gif' unless $noGif || -s $gif;
push @missing, 'step stills' unless @stills;
push @missing, 'srt' unless -s $srt;
push @missing, 'report' unless -s $md;

printf "clips: %d  duration: %.1fs  canvas: %dx%d\n", scalar(@segs), $total, $W, $H;
printf "steps: %d  pass: %d  fail: %d  skip: %d\n",
    scalar(@allcaps),
    scalar(grep { $_->{status} eq 'PASS' } @allcaps),
    scalar(grep { $_->{status} eq 'FAIL' } @allcaps),
    scalar(grep { $_->{status} eq 'SKIP' } @allcaps);
printf "jump cuts: %d\n", $total_cuts if $total_cuts;
print "video:  $mp4\n";
print "sheet:  $sheet\n" if !$noSheet && -s $sheet;
print "gif:    $gif\n" if $gif_made;
print "stills: $stepsdir (" . scalar(@stills) . ")\n";
print "srt:    $srt\n";
print "md:     $md\n";
die "missing output: " . join(', ', @missing) . "\n" if @missing;

# ---------- selfcheck ----------

if ($selfcheck) {
    my @check;
    my $probed = probe_video($mp4);
    my $ddiff = abs($probed->{dur} - $total);
    push @check, ['video duration', $ddiff < 1.0,
        sprintf('%.1fs rendered vs %.1fs expected', $probed->{dur}, $total)];
    push @check, ['step stills', scalar(@stills) == scalar(@allcaps),
        scalar(@stills) . ' stills for ' . scalar(@allcaps) . ' captions'];
    my $srt_rows = do {
        open my $rf, '<', $srt or die "cannot read $srt: $!\n";
        my $raw = do { local $/; <$rf> };
        () = $raw =~ / --> /g;
    };
    push @check, ['srt rows', $srt_rows == scalar(@allcaps),
        "$srt_rows rows for " . scalar(@allcaps) . ' captions'];
    push @check, ['report', -s $md, 'evidence.md written'];
    if (defined $voiceover) {
        my (undef, $vinfo) = run_cap($FF, '-hide_banner', '-i', $mp4);
        my $has_aac = $vinfo =~ /Audio:\s*aac/;
        push @check, ['voiceover audio', $has_aac ? 1 : 0,
            $has_aac ? 'aac stream in the mp4' : 'no aac stream in the mp4'];
    }
    if (!$noGif) {
        # decode to null and read the frame counter in ffmpeg's own stats
        # line; -count_frames belongs to ffprobe, which the one-file
        # bootstrap does not ship
        my (undef, $stats) = run_cap($FF, '-hide_banner', '-i', $gif, '-f', 'null', '-');
        my ($nf) = $stats =~ /frame=\s*(\d+)/;
        push @check, ['gif animates', defined $nf && $nf > 1, defined $nf ? "$nf frames" : 'no frames decoded'];
    }
    print "selfcheck:\n";
    my $failed = 0;
    for my $c (@check) {
        my ($name, $ok, $detail) = @$c;
        $failed++ unless $ok;
        printf "  %s %s (%s)\n", $ok ? 'PASS' : 'FAIL', $name, $detail;
    }
    exit($failed ? 1 : 0);
}
