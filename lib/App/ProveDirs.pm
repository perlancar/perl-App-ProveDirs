package App::ProveDirs;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use File::chdir;

our %SPEC;

sub _prove {
    require IPC::System::Options;

    my $opts = shift;

    my $stdout = "";
    my $stderr = "";

    my $act_stdout;
    my $act_stderr;
    if (log_is_warn()) {
        $act_stdout = "tee_stdout";
        $act_stderr = "tee_stderr";
    } else {
        $act_stdout = "capture_stdout";
        $act_stderr = "capture_stderr";
    }
    IPC::System::Options::system(
        {
            log=>1,
            ($act_stdout => \$stdout) x !!$act_stdout,
            ($act_stderr => \$stderr) x !!$act_stderr,
        },
        "prove", @{ $opts || [] },
        log_is_debug() ? ("-v") : (),
    );
    if ($?) {
        if ($stdout =~ /^Result: FAIL/m) {
            my $detail = "";
            if ($stdout =~ m!^(Failed \d+/\d+ subtests|No subtests run)!m) {
                $detail = " ($1)";
            }
            [500, "Test failed". $detail];
        } else {
            [500, "Non-zero exit code (".($? >> 8).")"];
        }
    } else {
        if ($stdout =~ /^Result: PASS/m) {
            [200, "PASS"];
        } elsif ($stdout =~ /^Result: NOTESTS/m) {
            [200, "NOTESTS"];
        } else {
            [500, "No PASS marker"];
        }
    }
}

# to be shared with prove-dists, prove-mods, prove-rdeps
our %args_common = (
    prove_opts => {
        summary => 'Options to pass to the prove command',
        'x.name.is_plural' => 1,
        'x.name.singular' => 'prove_opt',
        schema => ['array*', of=>'str*'],
        default => ['-l'],
    },
    summarize_all => {
        schema => 'bool*',
        summary => 'If true, also summarize successes in addition to failures',
    },
);

$SPEC{prove_dirs} = {
    v => 1.1,
    summary => 'Prove one or more directories',
    description => <<'_',

Given one or more directories as argument (which are assumed to be directories
of Perl distributions), this utility `cd` to each directory and run `prove` in
each. It then provides a summary at the end.

You can run with `--dry-run` (`-n`) option first to not actually run `prove` but
just see what directories will get tested. An example output:

    % prove-dirs perl-* -n
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Acme-CPANModules' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Data-Sah' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Data-Sah-Filter' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Date-strftimeq' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Log-ger' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Log-ger-Output-Screen' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Module-Installed-Tiny' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-Text-ANSITable' ...
    prove-dirs: [DRY] [1/8] Running prove in directory 'perl-lib-filter' ...

If we reinvoke the above command without the `-n`, *prove-dirs* will actually
run `prove` in each directory and provide a summary at the end. Example output:

    % prove-dirs perl-* -n
    ...
    +-----------------------------+-----------------------------------+--------+
    | dist                        | reason                            | status |
    +-----------------------------+-----------------------------------+--------+
    | perl-Acme-CPANModules       | Test failed (Failed 1/1 subtests) | 500    |
    | perl-Date-strftimeq         | Test failed (No subtests run)     | 500    |
    | perl-lib-filter             | Non-zero exit code (2)            | 500    |
    +-----------------------------+-----------------------------------+--------+

The above example shows that three directories (distributions) failed testing.
You can scroll up for the detailed `prove` output to see why they failed, fix
things, and re-run.

When a distribution's test fails, this counts as a 500 error (Error). Otherwise,
the status is 200 (OK).

*prove-dirs* will return status 200 (OK) with the status of each directory. It
will exit 0 if all directories are successful, otherwise it will exit 1.

_
    args => {
        %args_common,
        dirs => {
            summary => 'The directories',
            'x.name.is_plural' => 1,
            'x.name.singular' => 'dir',
            schema => ['array*', of=>'dirname*'],
            pos => 0,
            req => 1,
            slurpy => 1,
        },
        # XXX add arg: dzil test instead of prove
    },
    deps => {
        prog => 'prove',
    },
    features => {
        dry_run => 1,
    },
};
sub prove_dirs {
    my %args = @_;

    my @summaries;
    my $num_fails;
    my $i = 0;

    my (%dirs, @dirs);
    my $has_labels;
    if ($args{_dirs}) {
        %dirs = %{ $args{_dirs} };
        @dirs = sort { $dirs{$a} cmp $dirs{$b} } keys %dirs;
        $has_labels++;
    } else {
        @dirs = @{ $args{dirs} };
        %dirs = map { $_ => undef } @dirs;
    }

  DIR:
    for my $dir (@dirs) {
        $i++;
        my $label1 = $dirs{$dir} // $dir;
        my $label2 = $dirs{$dir} ? "$dirs{$dir} (directory $dir)" :
            "directory $dir";
        if ($args{-dry_run}) {
            log_info("[DRY] [%d/%d] Running prove for %s ...",
                     $i, scalar(@dirs), $label2);
            next DIR;
        }

        {
            local $CWD = $dir;
            log_info("[%d/%d] Running prove for %s ...",
                     $i, scalar(@dirs), $label2);
            my $pres = _prove($args{prove_opts});
            log_debug("Prove result: %s", $pres);
            my $summarize;
            if ($pres->[0] == 200) {
                # success
                $summarize++ if $args{summarize_all};
            } else {
                log_error "Test for %s failed: %s",
                    $dir, $pres->[1];
                $summarize++;
                $num_fails++;
            }
            if ($summarize) {
                push @summaries, {
                    dir=>$dir,
                    ($has_labels ? (label=>$label1) : ()),
                    status=>$pres->[0],
                    reason=>$pres->[1],
                };
            }
        }
    }

    [
        @{$num_fails == 0 ? [200, "All succeeded"] : $num_fails == @dirs ? [200, "All failed"] : [200, "Some failed"]},
        \@summaries,
        {'cmdline.exit_code' => $num_fails ? 1:0},
    ];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

See the included script L<prove-dirs>.


=head1 SEE ALSO

L<prove-dists> in L<App::ProveDists>

L<prove-mods> in L<App::ProveMods>

L<prove-rdeps> in L<App::ProveRdeps>

L<prove>
