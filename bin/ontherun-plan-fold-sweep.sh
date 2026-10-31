#!/usr/bin/env bash
# Sweep one plan for the stale echoes of a fold: every value the fold's diff removed that
# still stands somewhere in the plan the fold did not reach.
#
#   ontherun-plan-fold-sweep.sh [--all] [--rare N] <plan.md> <fold.diff>
#
# <fold.diff> is the file ontherun-plan-fold-diff.sh writes -- `git diff <base> -- <plan>`, one
# file -- and <plan.md> is that plan as it stands after the fold. The terms come from
# the diff's removed lines:
#
#   num       a number of three or more digits, or one carrying a point, a comma or a
#             range dash: 384, 3.45, 1,303, 3-60, 2026-09-07. Shorter integers count
#             only inside a pair; on their own they match everything
#   numword   zero .. twenty, thirty .. thousand, first .. twelfth, both, twice. A fold
#             that appends "(6)" to a list of five leaves "five rules" stale and removes
#             nothing to name it; that is ontherun-plan-lint.sh's self-count check, which fails
#             a plan on such a sentence before any spawn. A bare number word is not a
#             term: it fires on every list the fold did not touch
#   pair      a number or number word with the word beside it, either side, when that
#             word has two or more letters and is not an article or preposition: "384
#             dives", "round 1", "wave 2a", "six members"; and "release A", "phase B"
#   compound  a hyphenated word with a number in it: three-step, 1,303-line
#   code      a backticked span, matched exactly: `conform.WRITTEN`, `status: pending`.
#             Spans are paired over adjacent lines, so a command that wraps across two
#             changed lines is one span and one that wraps into an unchanged line is
#             not half a term. A bare node id (`py-4`), a heading reference (`##
#             Review history`), a hyphenated lowercase name (`acme-api`,
#             `fold-checker`) or a field name of the plan's own `## State` block
#             (`needs`, `status`) is skipped, as is a node id outside backticks:
#             references, not values, and each stands in twenty places in any plan
#   quote     a double-quoted span of two or more words; a one-word quote is a word
#   word      any other word of four or more letters that is not ordinary English (the
#             script carries the list: *returned*, *stands*, *everything* and the like)
#             -- listed only while it survives in at most N places plan-wide (--rare N,
#             default 6) and the fold wrote it nowhere else, because a removed word that
#             is rare is a leftover, one that is common is a reflow, and one the fold
#             re-used is a move
#
# **A term is what a hunk removed from a sentence it changed.** A hunk whose removed
# and added text are the same apart from whitespace and emphasis is a re-wrap and
# yields nothing; a removed sentence that survives verbatim in the added text yields
# nothing either. Every number, name, quote and pair the changed sentences lose is a
# term; one they keep is a term only when a word beside it changed -- a condition
# that grows from "open" to "open and corrected" keeps the word and moves what
# follows it, and still leaves every old statement of the condition stale. A name in a
# sentence whose other clause changed keeps both its neighbours and is not a term:
# listing those buries the real terms under kept values. The word tier is netted by
# count, a reworded sentence's plain words being rewording and not a value. A value
# re-stated in another sentence is flagged "also written by the fold": the total a
# decision cites and the count a scenario should have updated are the same number in
# different sections.
#
# Every term is then searched for in the whole plan after the fold, tolerant of a line
# wrap and of bold markers between its words, case-insensitive except for code, with a
# hit on a line the diff added skipped -- that is the fold's own text, which
# fold-checker reads. Hits outside `## Review history` are the survivors; hits inside
# it are listed apart by line number, since an entry narrating the old value is what
# that section is for. Terms with survivors come first: the values the fold removed,
# fewest survivors first; then the values a changed sentence kept beside a moved word;
# then the word tier -- each hit with its line and the nearest heading above it. Terms
# with none share one line at the end. A term surviving in more than 40 places -- a number
# word, more than 15 -- is summarised rather than listed, and any term's list stops at
# 12; `--all` lifts all three.
#
# **The fold's own new text is listed last, whatever was removed**: every added line
# the fold did not merely re-wrap that carries an absolute -- always, never, every,
# only, exactly, whatever, "the one", "the only", a duration -- or a backticked file
# path, with the words that matched. These are the sentences a fold-checker refutes
# most often, so each is a claim to run against the tree before the spawn, and a path is
# a file to `git show origin/<default>:`.
#
# Exit 0 when nothing survives outside `## Review history` and no added line is listed,
# 1 when something does or is, 2 when it could not run (a plan or diff it cannot read, a
# diff of more than one file or of a different file, a diff that no longer matches the
# plan -- regenerate it), 64 on usage. **1 is a list to read, not a verdict**: a survivor
# the conductor judges legitimate ("42 of the 384", where 384 is the total) is the
# ordinary reason to go on to the spawn.
#
# Why it exists: reference/plan-review-loop.md has the conductor sweep the
# plan after every fold, and fold-checker's second question is the same sweep by a clean
# reader; both otherwise decide what to grep for from memory, which misses the old
# value standing a hundred lines below the edit. What it cannot see is a rule added
# beside a sentence it contradicts: a fold that only adds leaves nothing to sweep for,
# and that stays the checker's to read and ontherun-plan-lint.sh's to check.
#
# Needs bash and perl (macOS ships it). ontherun-plan-fold-sweep.test.sh beside this file
# builds a plan and its fold in a throwaway repo and pins every shape above.

set -u

usage() { printf 'usage: %s [--all] [--rare N] <plan.md> <fold.diff>\n' "${0##*/}" >&2; exit 64; }

all=0
rare=6
while [ "$#" -gt 0 ]; do
  case $1 in
    --all) all=1; shift ;;
    --rare)
      [ "$#" -ge 2 ] || usage
      case $2 in ''|*[!0-9]*) usage ;; esac
      rare=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 2 ] || usage
plan=$1
diff=$2

for f in "$plan" "$diff"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf 'ontherun-plan-fold-sweep: cannot read %s\n' "$f" >&2
    exit 2
  fi
done
command -v perl >/dev/null || { printf 'ontherun-plan-fold-sweep: perl is required\n' >&2; exit 2; }

exec perl -CSDA - "$plan" "$diff" "$all" "$rare" <<'PERL'
use strict;
use warnings;

my ($plan_path, $diff_path, $all, $rare_max) = @ARGV;
my $CAP = 12;            # survivors listed per term before "and N more"
my $COMMON = 40;         # a term with more survivors than this is summarised, not listed
my $COMMON_NUMWORD = 15; # the same bound for a number word, whose survivors are mostly
                         # other counts, which would fill the report while the one
                         # stale count sits among them

sub fail { print STDERR "ontherun-plan-fold-sweep: $_[0]\n"; exit 2 }

sub slurp {
  my $p = shift;
  open my $fh, '<', $p or fail("cannot read $p: $!");
  local $/;
  my $s = <$fh>;
  close $fh;
  $s = '' unless defined $s;
  $s =~ s/\r\n/\n/g;
  return $s;
}

my @plan = split /\n/, slurp($plan_path), -1;
pop @plan if @plan && $plan[-1] eq '';
my @diff = split /\n/, slurp($diff_path), -1;
pop @diff if @diff && $diff[-1] eq '';

# ---------------------------------------------------------------- the diff, checked
#
# One file, and the plan as it is now: every context and added line is compared with
# the plan at the line the hunk header puts it, so a diff written before a later edit
# is refused rather than swept against the wrong text.
my @files = map { /^\+\+\+ (?:b\/)?(.*)$/ ? $1 : () } @diff;
fail("$diff_path is not a unified diff of one file") unless @files;
fail(sprintf('%s carries %d files; hand over ontherun-plan-fold-diff.sh\'s diff of the one plan', $diff_path, scalar @files))
  if @files > 1;
(my $plan_base = $plan_path) =~ s{.*/}{};
(my $diff_base = $files[0]) =~ s{.*/}{};
fail("$diff_path is a diff of $files[0], not of $plan_path") if $plan_base ne $diff_base;

my (@hunks, %added_ln);   # a hunk is [removed lines, added lines, added line numbers, removed line numbers]
sub check_line {
  my ($ln, $text) = @_;
  my $have = $ln >= 1 && $ln <= @plan ? $plan[$ln - 1] : undef;
  return if defined $have && $have eq $text;
  fail("the diff does not match $plan_path at line $ln; the plan has changed since it was written -- regenerate it with ontherun-plan-fold-diff.sh");
}
my $i = 0;
while ($i < @diff) {
  my $l = $diff[$i++];
  next unless $l =~ /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;
  my ($oln, $ln) = ($1, $2);
  my (@rem, @add, @addln, @remln);
  while ($i < @diff && $diff[$i] !~ /^@@ /) {
    my $d = $diff[$i++];
    if ($d =~ /^\\/) { next }
    elsif ($d =~ /^-/) { push @rem, substr($d, 1); push @remln, $oln; $oln++ }
    elsif ($d =~ /^\+/) { my $t = substr($d, 1); check_line($ln, $t); push @add, $t; push @addln, $ln; $added_ln{$ln} = 1; $ln++ }
    elsif ($d =~ /^ / || $d eq '') { check_line($ln, $d eq '' ? '' : substr($d, 1)); $ln++; $oln++ }
    else { last }
  }
  push @hunks, [\@rem, \@add, \@addln, \@remln];
}
fail("$diff_path carries no hunks") unless @hunks;

# ------------------------------------------------------------ headings and history
my (@head, @hist);
{
  my ($h, $in) = ('(top)', 0);
  for my $n (0 .. $#plan) {
    my $l = $plan[$n];
    if ($l =~ /^#{1,6}\s+(.*)/) {
      ($h = $1) =~ s/\s+$//;
      $in = 1 if $l =~ /^## Review history\b/;
      $in = 0 if $l =~ /^## / && $l !~ /^## Review history\b/;
    }
    $head[$n] = $h;
    $hist[$n] = $in;
  }
}

# ------------------------------------------------------------ the fold's own text
#
# An added line is new unless its text, whitespace collapsed, sits inside the hunk's
# removed text the same way -- that is a re-wrap, and the absolute in it is old. On a
# line that did change, a match is new only when the few characters around it are
# not in the removed text either: a changed count leaves the file name beside it old.
my $ABS = qr/\b(?:always|never|every|exactly|whatever|only|the one|the only|the single|\d+\s?(?:minutes?|seconds?|hours?)|minutes|hours)\b/i;
my $PATHSPAN = qr/`((?!plans\/)(?!#)[^`\s]*(?:\/[^`\s\/]+|\.(?:py|pyi|ts|tsx|js|mjs|swift|md|ya?ml|json|sh|toml|sql|html|css|ini|txt|cfg))(?::\d+(?:-\d+)?)?)`/;
my @flagged;
for my $h (@hunks) {
  my ($rem, $add, $addln) = @$h;
  (my $old = join ' ', @$rem) =~ s/\s+/ /g;
  for my $i (0 .. $#$add) {
    (my $t = $add->[$i]) =~ s/\s+/ /g;
    $t =~ s/^ | $//g;
    next if $t eq '' || index($old, $t) >= 0;
    my (@why, %seen);
    my $fresh = sub {
      my ($s, $e) = @_;
      my $from = $s - 12 < 0 ? 0 : $s - 12;
      my $left = substr($t, $from, $e - $from);
      my $right = substr($t, $s, $e - $s + 12);
      return index($old, $left) < 0 || index($old, $right) < 0;
    };
    while ($t =~ /$ABS/g) { my $w = lc $&; push @why, $w if $fresh->($-[0], $+[0]) && !$seen{$w}++ }
    while ($t =~ /$PATHSPAN/g) { my $p = $1; push @why, "`$p`" if $fresh->($-[0], $+[0]) && !$seen{$p}++ }
    push @flagged, [$addln->[$i], join('; ', @why)] if @why;
  }
}
sub report_flagged {
  return 0 unless @flagged;
  print "\n";
  printf "added lines to check before the spawn (%d): an absolute, or a file to read at origin/main, in text the fold wrote\n", scalar @flagged;
  for (@flagged) {
    my ($ln, $why) = @$_;
    (my $txt = $plan[$ln - 1]) =~ s/^\s+//;
    $txt = substr($txt, 0, 80) . "\x{2026}" if length($txt) > 81;
    printf "  %5d  %-30.30s  [%s]  %s\n", $ln, $head[$ln - 1], $why, $txt;
  }
  return scalar @flagged;
}

my $removed = 0;
$removed += @{ $_->[0] } for @hunks;
if (!$removed) {
  printf "ontherun-plan-fold-sweep: %d hunk%s, nothing removed; a fold that only adds leaves no old value to sweep for -- ontherun-plan-lint.sh and the checker's own reading are its checks\n",
    scalar @hunks, @hunks == 1 ? '' : 's';
  exit(report_flagged() ? 1 : 0);
}

# The field names of the plan's own `## State` block: `needs`, `status` and the rest
# are references wherever prose backticks them, and the block says which they are.
my %STATE_KEY;
{
  my $in = 0;
  for my $l (@plan) {
    if (!$in) { $in = 1 if $l =~ /^```yaml\s*$/; next }
    last if $l =~ /^```\s*$/;
    $STATE_KEY{$1} = 1 if $l =~ /^\s*(?:- )?([a-z_]+):/;
  }
}

# ------------------------------------------------------------------------- the terms
my %NUMWORD = map { $_ => 1 } qw(
  zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen
  fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy
  eighty ninety hundred thousand first second third fourth fifth sixth seventh eighth
  ninth tenth eleventh twelfth both twice
);
my %STOP = map { $_ => 1 } qw(
  a an the of to in on at by for from with as is are was were be been being and or but
  not no nor than that this these those it its into onto over under per each every all
  any some such only about after before between within without which who whom whose
  what when where while will would can could may might shall should must do does did
  done has have had having if then else so very more most less least own same other
  another via up down out off
);
# Ordinary English that clears the four-letter bar and the rarity bound anyway: a fold
# that rewords a sentence removes these, and a survivor of "returned" or "stands"
# elsewhere in the plan is never the stale value the word tier exists to find.
my %COMMONWORD = map { $_ => 1 } qw(
  about above across again against almost along already also although always among
  anything anyway anywhere around because become becomes before behind below beside
  besides beyond bring brought called cannot certain change changed changes come comes
  could does down during early either else enough even ever everything except exactly
  fact find follow following found further gets give given gives goes going gone
  great half have having here high however inside instead itself just keep keeps kept
  know known large last later least less like likely little long longer made make
  makes many mean means meant might much must near need needed needs never next
  nothing often once only other others otherwise part past place point rather really
  return returned returns right same says seem seems seen several should side sides
  since small some something sometimes soon stand stands start started starts state
  still such take taken takes than that their them then there these they thing things
  think this those though through thus times toward under until upon used uses using
  very want wants well went were what when where whether which while whole will with
  within without word words work would write written
);
my %LETTERKEY = map { $_ => 1 } qw(release phase tier appendix);
my %KORD = (code => 0, quote => 1, pair => 2, compound => 3, num => 4, numword => 5, word => 6);

# Backticked and quoted spans come out first, whole, over a hunk's lines joined -- a
# span that wraps is one span, and an unpaired backtick pairs with nothing; the rest is
# cut into pieces. A one-word quote is handed back as a word.
sub spans {
  my $t = shift;
  my @out;
  while ($t =~ s/`([^`]+)`/ /) { (my $c = $1) =~ s/\s+/ /g; push @out, ['code', $c] }
  while ($t =~ s/"([^"]{3,200}?)"/ /) { (my $q = $1) =~ s/\s+/ /g; push @out, [$q =~ /\s/ ? 'quote' : 'word', $q] }
  while ($t =~ s/\x{201C}([^\x{201D}]{3,200}?)\x{201D}/ /) { (my $q = $1) =~ s/\s+/ /g; push @out, [$q =~ /\s/ ? 'quote' : 'word', $q] }
  return (\@out, $t);
}

sub pieces {
  my $t = shift;
  $t =~ s/\*//g;
  my @p;
  for my $w (split /[\s\/|()\[\]{}<>;:!?]+/, $t) {
    $w =~ s/^[^\p{L}\d]+//;
    $w =~ s/[^\p{L}\d]+$//;
    $w =~ s/['\x{2019}]s\z//;
    push @p, $w if length $w;
  }
  return @p;
}

sub kind_of {
  my $w = shift;
  return 'num' if $w =~ /^\d[\d.,]*(?:[-\x{2013}]\d[\d.,]*)*[a-z]?$/;
  return 'numword' if $NUMWORD{ lc $w };
  if ($w =~ /-/) {
    return (grep { /^\d/ || $NUMWORD{ lc $_ } } split /-/, $w) ? 'compound' : 'word';
  }
  return 'word' if $w =~ /^\p{L}[\p{L}\d'\x{2019}]*$/;
  return '';
}

sub standalone { my $w = shift; return ($w =~ tr/0-9//) >= 3 || $w =~ /[.,\x{2013}-]/ }

sub is_node_id { return $_[0] =~ /^[a-z]+-\d+[a-z]?$/ }

# A backticked name that is a reference rather than a value: a heading, a node id, or a
# hyphenated lowercase name (a repo, an agent, a script).
sub is_reference {
  my $t = shift;
  return $t =~ /^#{1,6}\s/ || is_node_id($t) || $t =~ /^[a-z]+(?:-[a-z]+)+$/ || $STATE_KEY{$t};
}

sub keyof {
  my ($k, $t) = @_;
  my $n = $k eq 'code' ? $t : lc $t;
  $n =~ s/\s+/ /g;
  return "$k\t$n";
}

# One hunk side -> { key => count }; the first spelling seen goes to $disp.
sub collect {
  my ($lines, $disp) = @_;
  my %c;
  my $add = sub { my ($kind, $t) = @_; my $key = keyof($kind, $t); $c{$key}++; $disp->{$key} //= $t };
  my ($sp, $rest) = spans(join "\n", @$lines);
  for (@$sp) {
    my ($k, $t) = @$_;
    if ($k eq 'code') { $add->($k, $t) unless is_reference($t) }
    elsif ($k eq 'word') { $add->($k, $t) if length($t) >= 4 && !$STOP{ lc $t } && !$COMMONWORD{ lc $t } }
    else { $add->($k, $t) }
  }
  my @stream = pieces($rest);
  my $beside = sub { my $n = shift; kind_of($n) eq 'word' && length($n) >= 2 && !$STOP{ lc $n } };
  for my $j (0 .. $#stream) {
    my $w = $stream[$j];
    my $k = kind_of($w);
    my $lw = lc $w;
    if ($k eq 'num' || $k eq 'numword') {
      $add->('pair', "$stream[$j-1] $w") if $j > 0 && $beside->($stream[$j - 1]);
      $add->('pair', "$w $stream[$j+1]") if $j < $#stream && $beside->($stream[$j + 1]);
      $add->($k, $w) if $k eq 'numword' || standalone($w);
    } elsif ($k eq 'compound') {
      $add->('compound', $w) unless is_node_id($w);
    } elsif ($k eq 'word') {
      $add->('word', $w) if length($w) >= 4 && !$STOP{$lw} && !$COMMONWORD{$lw};
      $add->('pair', "$w $stream[$j+1]")
        if $LETTERKEY{$lw} && $j < $#stream && $stream[$j + 1] =~ /^[A-Z]$/;
    }
  }
  return \%c;
}

# One side of a hunk as runs of adjacent lines, each run's backticks made even. A span
# pairs only within a run: two removed lines with an unchanged line between them are
# not one text, and a span that wraps from a changed line into an unchanged one has
# one backtick on this side and must not pair with the next span's opener -- that is
# where junk terms like `, ` came from. Which backtick is the stray is decided by what
# pairs best: each one is tried, and the one whose removal leaves the fewest ugly
# spans -- a span that begins or ends with punctuation or a space, carries a sentence
# stop, or runs past 120 characters -- is dropped, the last of equals winning. The
# stray is not always at an end: a quoted sentence with a backtick inside it puts one
# in the middle of a run.
sub runs {
  my ($lines, $lns) = @_;
  my @out;
  for my $i (0 .. $#$lines) {
    if ($i > 0 && $lns->[$i] == $lns->[$i - 1] + 1) { $out[-1] .= "\n" . $lines->[$i] }
    else { push @out, $lines->[$i] }
  }
  return map { mend($_) } @out;
}
sub mend {
  my $t = shift;
  my @at;
  push @at, pos($t) - 1 while $t =~ /`/g;
  return $t if @at % 2 == 0;
  my $ugly = sub { scalar grep { /^[\s),;:.]|[\s(,;:]$|[.;!?]\s|.{120}/ } $_[0] =~ /`([^`]+)`/g };
  my ($best, $score);
  for my $p (@at) {
    my $try = substr($t, 0, $p) . substr($t, $p + 1);
    my $u = $ugly->($try);
    ($best, $score) = ($try, $u) if !defined $score || $u <= $score;
  }
  return $best;
}

# A hunk's text with its whitespace collapsed, cut into sentences at a stop outside
# backticks -- a command in a span carries stops of its own. Sentences are compared
# with emphasis ignored, but only outside backticks: a `*` inside a span is a glob and
# part of the name, and the terms are collected from the text with it intact.
sub norm { my $t = join ' ', @{ $_[0] }; $t =~ s/\s+/ /g; $t =~ s/^ | $//g; return $t }

# The text as a token stream -- a span or a quote is one token, a word is one token --
# and each token with its two neighbours. A value a changed sentence keeps is at the
# change only if one of its neighbours differs from every neighbour it has on the
# added side: "to be `open`." against "to be `open` and corrected" moves the word
# after it, while a name in a sentence whose other clause changed keeps both.
sub tokens {
  my $t = shift;
  my @out;
  while ($t =~ /`([^`]+)`|"([^"]{3,200}?)"|([^\s`"]+)/g) {
    if (defined $1) { (my $c = $1) =~ s/\s+/ /g; push @out, $c; next }
    if (defined $2) { (my $q = $2) =~ s/\s+/ /g; push @out, lc $q; next }
    my $w = $3;
    $w =~ s/\*//g;
    $w =~ s/^[^\p{L}\d]+//;
    $w =~ s/[^\p{L}\d]+$//;
    $w =~ s/['\x{2019}]s\z//;
    push @out, lc $w if length $w;
  }
  return @out;
}
sub triples {
  my @t = ('^', @_, '$');
  return map { "$t[$_-1]\t$t[$_]\t$t[$_+1]" } 1 .. $#t - 1;
}
sub at_change {
  my ($removed, $added) = @_;
  my %have = map { $_ => 1 } triples(tokens($added));
  my %moved;
  for (triples(tokens($removed))) { my (undef, $tok) = split /\t/; $moved{$tok} = 1 unless $have{$_} }
  return \%moved;
}
sub plain {
  my @seg = split /(`[^`]*`)/, $_[0];
  for (@seg) { s/\*//g unless /^`/ }
  return join '', @seg;
}
sub sentences {
  my $t = shift;
  my @out;
  my ($ticks, $start) = (0, 0);
  while ($t =~ /(`)|[.;!?]\**(\s+)/g) {
    if (defined $1) { $ticks++; next }
    next if $ticks % 2;
    push @out, substr($t, $start, pos($t) - length($2) - $start);
    $start = pos($t);
  }
  push @out, substr($t, $start) if $start < length $t;
  return @out;
}

# A value a changed sentence keeps is a term only when it is the kind that carries a
# condition -- a name, a quote, a number, or a pair on a real count. "one", "first",
# "both" and "twice" ride along with any rewording and carry nothing, and a kept
# "release C" is a reference.
my %WEAK = map { $_ => 1 } qw(one first both twice once second);
sub carries {
  my ($kind, $n) = @_;
  return 1 if $kind eq 'code' || $kind eq 'quote' || $kind eq 'num';
  return 0 if $n =~ / [a-z]$/;
  return !grep { $WEAK{ lc $_ } } split / /, $n;
}

my (%term, %also, %disp, %kept_term);
for my $h (@hunks) {
  my ($rem, $add, $addln, $remln) = @$h;
  my @rruns = runs($rem, $remln);
  my @aruns = runs($add, $addln);
  my ($rt, $at) = (norm(\@rruns), norm(\@aruns));
  my $a = collect(\@aruns, {});
  $also{$_} = 1 for keys %$a;
  next if plain($rt) eq plain($at);
  my %kept = map { plain($_) => 1 } sentences($at);
  my @changed = grep { !$kept{ plain($_) } } sentences($rt);
  my $r = collect(\@changed, \%disp);
  my $w = collect(\@rruns, \%disp);
  my $moved = at_change($rt, $at);
  for my $k (keys %$r) {
    next if $k =~ /^word\t/;
    my ($kind, $n) = split /\t/, $k, 2;
    my $retained = ($a->{$k} // 0) >= ($w->{$k} // 0);
    my $beside_change = grep { $moved->{$_} } ($kind eq 'code' || $kind eq 'quote' ? $n : split / /, $n);
    if (!$retained) { $term{$k} = 1; delete $kept_term{$k} }
    elsif (carries($kind, $n) && $beside_change) { $kept_term{$k} = 1 unless $term{$k}; $term{$k} = 1 }
  }
  for my $k (grep { /^word\t/ } keys %$w) { $term{$k} = 1 if $w->{$k} > ($a->{$k} // 0) }
}
if (!%term) {
  printf "ontherun-plan-fold-sweep: %d hunk%s, %d removed line%s, 0 terms; every removed value is re-stated in its own hunk\n",
    scalar @hunks, @hunks == 1 ? '' : 's', $removed, $removed == 1 ? '' : 's';
  exit(report_flagged() ? 1 : 0);
}

# ------------------------------------------------------------------------ the search
my $text = join "\n", @plan;
my @start;
{ my $o = 0; for (@plan) { push @start, $o; $o += length($_) + 1 } }
sub line_at {
  my $pos = shift;
  my ($lo, $hi) = (0, $#start);
  while ($lo < $hi) {
    my $mid = int(($lo + $hi + 1) / 2);
    if ($start[$mid] <= $pos) { $lo = $mid } else { $hi = $mid - 1 }
  }
  return $lo + 1;
}

my $GAP = '[\s*]+';
sub pattern {
  my ($k, $t) = @_;
  if ($k eq 'code') {
    my $body = join '\s+', map { quotemeta } split /\s+/, $t;
    return qr/(?<![\w.-])$body(?![\w-]|\.\w)/;
  }
  return qr/(?<![\d.,\x{2013}-])\Q$t\E(?!\d|[.,]\d|[\x{2013}-]\d)/ if $k eq 'num';
  my $body = join $GAP, map { quotemeta } split /\s+/, $t;
  return qr/(?<![\p{L}\d])$body(?![\p{L}\d])/i;
}

my (%body, %histl, @common);
for my $key (keys %term) {
  my ($k) = split /\t/, $key, 2;
  my $re = pattern($k, $disp{$key});
  my (@b, @h);
  while ($text =~ /$re/g) {
    my $ln = line_at($-[0]);
    next if $added_ln{$ln};
    my $slot = $hist[$ln - 1] ? \@h : \@b;
    push @$slot, $ln unless @$slot && $slot->[-1] == $ln;
  }
  if ($k eq 'word' && $also{$key}) { delete $term{$key}; next }
  if ($k eq 'word' && @b + @h > $rare_max) { push @common, $disp{$key}; delete $term{$key}; next }
  $body{$key} = \@b;
  $histl{$key} = \@h;
}

# ------------------------------------------------------------------------ the report
sub render {
  my ($k, $t) = @_;
  return "`$t`" if $k eq 'code';
  return "\"$t\"" if $k eq 'quote' || $k eq 'pair';
  return $t;
}
my $by_rank = sub {
  my ($ka) = split /\t/, $a, 2;
  my ($kb) = split /\t/, $b, 2;
  ($ka eq 'word') <=> ($kb eq 'word')
    || ($kept_term{$a} ? 1 : 0) <=> ($kept_term{$b} ? 1 : 0)
    || @{ $body{$a} } <=> @{ $body{$b} } || $KORD{$ka} <=> $KORD{$kb} || lc $disp{$a} cmp lc $disp{$b};
};
my @with = sort $by_rank grep { @{ $body{$_} } } keys %term;
my @without = sort $by_rank grep { !@{ $body{$_} } } keys %term;

printf "ontherun-plan-fold-sweep: %d hunk%s, %d removed line%s, %d term%s; %d with survivors outside ## Review history\n",
  scalar @hunks, @hunks == 1 ? '' : 's', $removed, $removed == 1 ? '' : 's',
  scalar keys %term, keys(%term) == 1 ? '' : 's', scalar @with;

for my $key (@with) {
  my ($k) = split /\t/, $key, 2;
  my @b = @{ $body{$key} };
  my @h = @{ $histl{$key} };
  my $summary = sprintf '%d outside ## Review history', scalar @b;
  $summary .= sprintf ', %d in it', scalar @h if @h;
  $summary .= ', also written by the fold' if $also{$key};
  print "\n";
  if (@b > ($k eq 'numword' ? $COMMON_NUMWORD : $COMMON) && !$all) {
    printf "%-8s %s  %s -- not listed, a term this common is noise; --all lists them\n", $k, render($k, $disp{$key}), $summary;
    next;
  }
  printf "%-8s %s  %s\n", $k, render($k, $disp{$key}), $summary;
  my @show = $all || @b <= $CAP ? @b : @b[0 .. $CAP - 1];
  for my $ln (@show) {
    (my $txt = $plan[$ln - 1]) =~ s/^\s+//;
    $txt = substr($txt, 0, 100) . "\x{2026}" if length($txt) > 101;
    printf "  %5d  %-30.30s  %s\n", $ln, $head[$ln - 1], $txt;
  }
  printf "         and %d more; --all lists them\n", @b - @show if @b > @show;
  if (@h) {
    my @hs = $all || @h <= 20 ? @h : (@h[0 .. 19], "\x{2026}");
    printf "         ## Review history: %s\n", join ', ', @hs;
  }
}

if (@without) {
  print "\n";
  print 'no survivors outside ## Review history: ',
    join(', ', map {
      my ($k) = split /\t/, $_, 2;
      my $s = "$k " . render($k, $disp{$_});
      $s .= sprintf ' (%d in it)', scalar @{ $histl{$_} } if @{ $histl{$_} };
      $s
    } @without), "\n";
}
if (@common) {
  print "\n";
  printf "skipped as common (more than %d survivors; --rare N raises it): %s\n", $rare_max, join ', ', sort { lc $a cmp lc $b } @common;
}

my $listed = report_flagged();
exit(@with || $listed ? 1 : 0);
PERL
