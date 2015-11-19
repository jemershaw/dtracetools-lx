#!/bin/sh
#
# dtruss - print process system call time details.
#          Written using DTrace (Solaris 10 3/05).
#
# $Id: dtruss 9 2007-08-07 10:21:07Z brendan $
#
# USAGE: dtruss [-acdeflhoLs] [-t syscall] { -p PID | -n name | command }
#
#		-p PID		# examine this PID
#		-n name		# examine this process name
#		-t syscall	# examine this syscall only
#		-a		# print all details
#		-c		# print system call counts
#		-d		# print relative timestamps (us)
#		-e		# print elapsed times (us)
#		-f		# follow children as they are forked
#		-l		# force printing of pid/lwpid per line
#		-o		# print on cpu times (us)
#		-s		# print stack backtraces
#		-L		# don't print pid/lwpid per line
#		-b bufsize	# dynamic variable buf size (default is "4m")
#  eg,
#		dtruss df -h	# run and examine the "df -h" command
#		dtruss -p 1871	# examine PID 1871
#		dtruss -n tar	# examine all processes called "tar"
#		dtruss -f test.sh	# run test.sh and follow children
#
# See the man page dtruss(1M) for further details.
#
# SEE ALSO: procsystime    # DTraceToolkit
#           dapptrace      # DTraceToolkit
#           truss
#
# COPYRIGHT: Copyright (c) 2005, 2006, 2007 Brendan Gregg.
#
# CDDL HEADER START
#
#  The contents of this file are subject to the terms of the
#  Common Development and Distribution License, Version 1.0 only
#  (the "License").  You may not use this file except in compliance
#  with the License.
#
#  You can obtain a copy of the license at Docs/cddl1.txt
#  or http://www.opensolaris.org/os/licensing.
#  See the License for the specific language governing permissions
#  and limitations under the License.
#
# CDDL HEADER END
#
# TODO: Track signals, more output formatting.  More expansion of args for lx
# (and non-SmartOS) syscalls would be nice.
#
# 29-Apr-2005   Brendan Gregg   Created this.
# 09-May-2005      "      " 	Fixed evaltime (thanks Adam L.)
# 16-May-2005	   "      "	Added -t syscall tracing.
# 17-Jun-2005	   "      "	Added -s stack backtraces.
# 17-Jun-2005	   "      "	Last update.
# 29-Jun-2007	   "      "	Used progenyof() (thanks Aaron Gutman).
# 06-Aug-2007	   "      "	Various updates.
# 17-Nov-2015   Max Bruning     Modified for lx system calls on lx
#


##############################
# --- Process Arguments ---
#

### Default variables
opt_pid=0; opt_name=0; pid=0; pname="."; opt_elapsed=0; opt_cpu=0
opt_counts=0; opt_relative=0; opt_printid=0; opt_follow=0; opt_command=0
command=""; opt_buf=0; buf="4m"; opt_trace=0; trace="."; opt_stack=0

### Process options
while getopts ab:cdefhln:op:st:L name
do
        case $name in
	b)	opt_buf=1; buf=$OPTARG ;;
        p)      opt_pid=1; pid=$OPTARG ;;
        n)      opt_name=1; pname=$OPTARG ;;
        t)      opt_trace=1; trace=$OPTARG ;;
	a)	opt_counts=1; opt_relative=1; opt_elapsed=1; opt_follow=1
		opt_printid=1; opt_cpu=1 ;;
	c)	opt_counts=1 ;;
	d)	opt_relative=1 ;;
	e)	opt_elapsed=1 ;;
	f)	opt_follow=1 ;;
	l)	opt_printid=1 ;;
	o)	opt_cpu=1 ;;
	L)	opt_printid=-1 ;;
	s)	opt_stack=-1 ;;
        h|?)    cat <<-END >&2
		USAGE: dtruss [-acdefholLs] [-t syscall] { -p PID | -n name | command }

		          -p PID          # examine this PID
		          -n name         # examine this process name
		          -t syscall      # examine this syscall only
		          -a              # print all details
		          -c              # print syscall counts
		          -d              # print relative times (us)
		          -e              # print elapsed times (us)
		          -f              # follow children (-p or cmd only)
		          -l              # force printing pid/lwpid
		          -o              # print on cpu times
		          -s              # print stack backtraces
		          -L              # don't print pid/lwpid
		          -b bufsize      # dynamic variable buf size
		   eg,
		       dtruss df -h       # run and examine "df -h"
		       dtruss -p 1871     # examine PID 1871
		       dtruss -n tar      # examine all processes called "tar"
		       dtruss -f test.sh  # run test.sh and follow children
		END
		exit 1
        esac
done
shift `expr $OPTIND - 1`

### Option logic
if [ $opt_pid -eq 0 -a $opt_name -eq 0 ]; then
	opt_command=1
	if [ "$*" = "" ]; then
		$0 -h
		exit
	fi
	command="$*"	# yes, I meant $*!
fi
if [ $opt_follow -eq 1 -o $opt_name -eq 1 ]; then
	if [ $opt_printid -ne -1 ]; then
		opt_printid=1
	else
		opt_printid=0
	fi
fi
if [ $opt_follow -eq 1 -a $opt_name -eq 1 ]; then
	echo "ERROR: -f option cannot be used with -n (use -p or cmd instead)."
	exit 1
fi

### Option translation
if [ "$trace" = "exec" ]; then trace="exece"; fi
if [ "$trace" = "time" ]; then trace="gtime"; fi
if [ "$trace" = "exit" ]; then trace="rexit"; fi


#################################
# --- Main Program, DTrace ---
#

### Define D Script
dtrace='
#pragma D option quiet
#pragma D option switchrate=10
 
/*
 * Command line arguments
 */
inline int OPT_command   = '$opt_command';
inline int OPT_follow    = '$opt_follow';
inline int OPT_printid   = '$opt_printid';
inline int OPT_relative  = '$opt_relative';
inline int OPT_elapsed   = '$opt_elapsed';
inline int OPT_cpu       = '$opt_cpu';
inline int OPT_counts    = '$opt_counts';
inline int OPT_pid       = '$opt_pid';
inline int OPT_name      = '$opt_name';
inline int OPT_trace     = '$opt_trace';
inline int OPT_stack     = '$opt_stack';
inline string NAME       = "'$pname'";
inline string TRACE      = "'$trace'";

dtrace:::BEGIN 
{
	/* print header */
	OPT_printid  ? printf("%-9s  ", "PID/LWP") : 1;
	OPT_relative ? printf("%8s ", "RELATIVE") : 1;
	OPT_elapsed  ? printf("%7s ", "ELAPSD") : 1;
	OPT_cpu      ? printf("%6s ", "CPU") : 1;
	printf("SYSCALL(args) \t\t = return\n");
}

/*
 * Save syscall entry info
 */
lx-syscall:::entry
/((OPT_command || OPT_pid) && pid == $target) || 
 (OPT_name && execname == NAME) ||
 (OPT_follow && progenyof($target))/
{
	/* set start details */
	self->start = timestamp;
	self->vstart = vtimestamp;
	self->arg0 = arg0;
	self->arg1 = arg1;
	self->arg2 = arg2;

	/* count occurances */
	OPT_counts == 1 ? @Counts[probefunc] = count() : 1;
}

/*
 * Follow children
 */
lx-syscall::fork*:return
/(OPT_follow && progenyof($target)) && (!OPT_trace || (TRACE == probefunc))/
{
	/* print output */
	self->code = errno == 0 ? "" : "Err#";
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d:  ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d:  ", 0) : 1;
	OPT_cpu      ? printf("%6d ", 0) : 1;
	printf("%s(0x%X, 0x%X, 0x%X)\t\t = %d %s%d\n", probefunc,
	    self->arg0, self->arg1, self->arg2, (int)arg0, self->code,
	    (int)errno);
}

/*
 * Check for syscall tracing
 */
lx-syscall:::entry
/OPT_trace && probefunc != TRACE/
{
	/* drop info */
	self->start = 0;
	self->vstart = 0;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/*
 * Print return data
 */


/* print 3 args, arg0 as a string */
lx-syscall::stat*:return, 
lx-syscall::lstat*:return, 
lx-syscall::open*:return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(\"%S\", 0x%X, 0x%X)\t\t = %d %s%d\n", probefunc,
	    copyinstr(self->arg0), self->arg1, self->arg2, (int)arg0,
	    self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/* print 3 args, arg1 as a string */
lx-syscall::write:return,
lx-syscall::*read*:return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(0x%X, \"%S\", 0x%X)\t\t = %d %s%d\n", probefunc, self->arg0,
	    stringof(copyin(self->arg1, self->arg2)), self->arg2, (int)arg0,
	    self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/* print 0 arg output */
lx-syscall::*fork*:return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s()\t\t = %d %s%d\n", probefunc,
	    (int)arg0, self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/* print 1 arg output */
lx-syscall::brk:return,
lx-syscall::times:return,
lx-syscall::stime:return,
lx-syscall::close:return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(0x%X)\t\t = %d %s%d\n", probefunc, self->arg0,
	    (int)arg0, self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/* print 2 arg output */
lx-syscall::utime:return,
lx-syscall::munmap:return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(0x%X, 0x%X)\t\t = %d %s%d\n", probefunc, self->arg0,
	    self->arg1, (int)arg0, self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

/* print 3 arg output - default */
lx-syscall:::return
/self->start/
{
	/* calculate elapsed time */
	this->elapsed = timestamp - self->start;
	self->start = 0;
	this->cpu = vtimestamp - self->vstart;
	self->vstart = 0;
	self->code = errno == 0 ? "" : "Err#";
 
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(0x%X, 0x%X, 0x%X)\t\t = %d %s%d\n", probefunc, self->arg0,
	    self->arg1, self->arg2, (int)arg0, self->code, (int)errno);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
	self->arg0 = 0;
	self->arg1 = 0;
	self->arg2 = 0;
}

lx-syscall::exit_group:entry
/pid == $target/
{
	/* print optional fields */
	OPT_printid  ? printf("%6d/%d:  ", pid, tid) : 1;
	OPT_relative ? printf("%8d ", vtimestamp/1000) : 1;
	OPT_elapsed  ? printf("%7d ", this->elapsed/1000) : 1;
	OPT_cpu      ? printf("%6d ", this->cpu/1000) : 1;
 
	/* print main data */
	printf("%s(0x%X)\n", probefunc, arg0);
	OPT_stack ? ustack()    : 1;
	OPT_stack ? trace("\n") : 1;
}	
/* program exited */
proc:::exit
/(OPT_command || OPT_pid) && pid == $target/
{
	exit(0);
}

/* print counts */
dtrace:::END
{
	OPT_counts == 1 ? printf("\n%-32s %16s\n", "CALL", "COUNT") : 1;
	OPT_counts == 1 ? printa("%-32s %@16d\n", @Counts) : 1;
}
'

### Run DTrace
if [ $opt_command -eq 1 ]; then
	/native/usr/sbin/dtrace -x temporal -x dynvarsize=$buf -x evaltime=exec -n "$dtrace" \
	    -c "$command" >&2
elif [ $opt_pid -eq 1 ]; then
	/native/usr/sbin/dtrace -x temporal -x dynvarsize=$buf -n "$dtrace" -p "$pid" >&2
else
	/native/usr/sbin/dtrace -x temporal -x dynvarsize=$buf -n "$dtrace" >&2
fi
