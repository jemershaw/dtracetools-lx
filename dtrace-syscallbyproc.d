#!/native/usr/sbin/dtrace -s
/*
 * syscallbyproc.d - report on syscalls by process name . DTrace OneLiner.
 *
 * This is a DTrace OneLiner from the DTraceToolkit.
 *
 * $Id: syscallbyproc.d 3 2007-08-01 10:50:08Z brendan $
 *
 * 11-Nov-2015  Joyent          Updated for LX.
 */
lx-syscall:::entry { @num[execname] = count(); }
