vzrepair
=========

**vzrepair** - script for OpenVZ 6 for boot container to repair mode (same as repair from PCS/Virtuozzo)

It work on CentOS 6 and only with ploop based containers.

License: GPLv2

Install
========
```
wget  --no-check-certificate https://raw.githubusercontent.com/FastVPSEestiOu/vzrepair/master/vzrepair.pl -O /usr/local/sbin/vzrepair
chmod +x /usr/local/sbin/vzrepair
wget --no-check-certificate https://raw.githubusercontent.com/FastVPSEestiOu/vzrepair/master/open_vestat_bash_completion -O /etc/bash_completion.d/vzrepair_bash_completion
```

Usage
=======
```
vzrepair.pl [ --help ] < --ctid CTID > [ --start | --stop | --status ] 
```

Options
========
- --help  Print help message

- --ctid  Container CTID

-  --start     Start repair - stop container if it running, create and start repair container, mount root.hdd from main container to /repair/

*  --password  Used only whith --start . Set password to repair container. By default(without  param) - use password from main container. If set "rand" - set random  pass.

*  --template  Used only whith --start . Set maunal template for repair container. Use $set_only_local_templates variable, for use it only with local templates or not

- --stop      Stop repair - stop and delete repair container

- --status    Show status - we have repair container for this CTID or not

- --silent    Not show debug output(json output be print)

- --json      Print json message, use it with --silent, to have only json output

Description
============
We use 1000000000+ number for repair CTIDs.

Repair CTID = CTID + 1000000000.

Hostname changed to "repair.HOSTNAME" on repair container.

In fact it create new container and mount ploop from needed container to /repair/ directory.

And it add to new container chroot-prepair script for more simple chroot in /repair/.

Please see check_and_change_ostemplate sub - it have rules for mutate ostemplate(used if you not set template via --template key)
