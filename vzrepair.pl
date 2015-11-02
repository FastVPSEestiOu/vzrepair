#!/usr/bin/perl

use strict;
use warnings;

use POSIX qw(locale_h);
use POSIX qw(strftime);
use Term::ANSIColor;
use Pod::Usage qw(pod2usage);
use Getopt::Long;


my $log_file = "/var/log/vzrepair.log";
setlocale(LC_ALL, "en_US");
my $debug = 1;
my $set_only_local_templates = 1;

#The offset between the CTID container and CTID repair container
my $ctid_seek = 1000000000;
my $vzctl = "/usr/sbin/vzctl";
my $vzlist = "/usr/sbin/vzlist";
my $ploop = "/usr/sbin/ploop";
my $vztmpl_dl = "/usr/sbin/vztmpl-dl";



my $ctid;
my $start;
my $stop;
my $repair_status;
my $password;
my $set_template = "";

my $help = "";
my $silent;
my $json = "";

my $repair_ctid = -1;
my $is_ct_running = 0;
my $ct_config;

GetOptions (
    "ctid=s"     =>  \$ctid,     # Container ctid
    "start"      =>  \$start,    # Start repair
    "stop"       =>  \$stop,     # Stop repair
    "status"     =>  \$repair_status,   # status of repair
    "password=s" =>  \$password, # Set password to repair container
    "template=s" =>  \$set_template, # Set template for repair container
    "help"       =>  \$help,     # help
    "silent"     =>  \$silent,   # not output
    "json"       =>  \$json,     # add json output

) 
or pod2usage( -message => "\nError in command line arguments!\n", -verbose => 1, -noperldoc => 1, -exitval => 1,);

#If help - only help
if ($help) {
    pod2usage( -verbose => 2, -noperldoc => 1 );
    exit 0;
}

#Disable output 
if ($silent) {
    $debug = 0;
}

my $text_for_json =  "";

open my $log_file_handle, ">>", $log_file or die "Cannot open to write $log_file: $!\n";

main();

close $log_file_handle;

sub main {

    if ( defined $ctid ) {
    
        # correct ctid?
        if ( $ctid !~ /^\d+\z/ ) {
            debug_print("error", "$ctid is cannot be correct ctid!");
            print_json(qq/{"error_message":"$ctid is cannot be correct ctid!"}/) if $json;
            exit 1;
        }

        # We have repair ctid number?
        if ( $ctid < $ctid_seek ) {
            $repair_ctid = $ctid + $ctid_seek; 
        } 
        elsif ( $ctid > $ctid_seek ) {
            $repair_ctid = $ctid;
            $ctid = $repair_ctid - $ctid_seek;
        }

        my $ctid_status = get_ctid_status($ctid);
        $is_ct_running = 1  if $ctid_status =~ / running$/;

        # Start repair
        if ( $start ) {

            # repair range ctid?
            if ( $ctid >= $ctid_seek ) {
                debug_print("error", "It is repair range! Do not try use repair for repair container, please!");
                print_json(qq/{"error_message":"It is repair range! Do not try use repair for repair container, please!"}/) if $json;
                exit 1;
            }

            # We have this old_ctid or new_ctid on node?
            if ( $ctid_status !~ / exist / ) {
                debug_print("error", "We have not CTID \"$ctid\" on this node!");
                print_json(qq/{"error_message":"We have not CTID \"$ctid\" on this node"}/) if $json;
                exit 1;
            }

            debug_print("info", "Start repair for CTID $ctid");
            start_repair_for_ctid($ctid);
        }
    
        # Only get repair status
        if ($repair_status) {
            debug_print("info", "Get repair status for $ctid");
            get_repair_status_for_ctid($ctid);
        }
    
        # Stop repair
        if ($stop) {
            debug_print("info", "Stop repair for $ctid");
            stop_repair_for_ctid($ctid);
        }
    
        if ( not ($start && $stop && $repair_ctid) ) {
            pod2usage( -message => "You not choose action after CTID - start/stop/status!\n", -verbose => 1, -noperldoc => 1, -exitval => 1,);
        }
        
    }
    else {
        pod2usage( -message => "You must set --ctid CTID!\n", -verbose => 1, -noperldoc => 1, -exitval => 1,);
    }
    return 1;
}


sub debug_print {
    my $warn = shift;
    my $text = shift;
    my $date = strftime "%a %b %e %H:%M:%S %Y",localtime;

    my %warn_colors = (
        'error'   => 'bold red',
        'warning' => 'bold yellow',
        'info'    => 'bold green',
    );

    print $log_file_handle "$date [$warn] $text\n";
    if ( $debug ) {
        if ( defined $warn_colors{$warn} ) {
            print color 'reset';
            print "$date [";
            print color $warn_colors{$warn};
            print $warn;
            print color 'reset';
            print "] $text\n";
        }
        else {
            print "$date [$warn] $text\n";
        }
    }
    return 1;
}


sub get_ctid_status {
    my $ctid = shift;

    my $ctid_status = `$vzctl status $ctid 2>&1`;
    chomp $ctid_status;
    $ctid_status =~ s/\n/ /;
    if ($?) {
        debug_print("error", "We cannot get $ctid status! $ctid_status");
        print_json(qq/{"error_message":"We cannot get $ctid status! $ctid_status"}/) if $json;
        exit 1;
    }
    else {
        debug_print("info", "$ctid status - $ctid_status");
    }
    
    return $ctid_status;   
}

sub parse_ct_config_to_hash {
    my $ctid = shift;    
    my $ct_config;

    my $open_config_result = open my $config_handle, "<", "/etc/vz/conf/$ctid.conf";
    if ( not $open_config_result ) {
        debug_print("error", "We cannot open config for $ctid: $!");
        return 0;
    }
    while ( my $line = <$config_handle> ){
        chomp $line;
        next if $line =~ /^#/;
        if ( $line =~ /=/ ) {
            my ($param, $value) = split /=/, $line;
            chomp $param; chomp $value;
            $value =~ s/"//g;
            $ct_config->{$param} = $value;
        }
    }
    close $config_handle;

    return $ct_config;
}

sub create_repair_container {
    my $ctid = shift;
    
    my $config_file = "/etc/vz/conf/$ctid.conf";
    my $ct_config_repair = { %$ct_config };

    # Set new param for container

    my $ostemplate = "";
    if ($set_template) {
        if ($set_only_local_templates){
            my @local_template_list = get_local_templates_list();
            if (scalar @local_template_list) {
                if (grep {/^$set_template$/} @local_template_list){
                    debug_print("info", "You set template to \"$set_template\" and we use it for repair container");
                    $ostemplate = $set_template;
                }
                else {
                    debug_print("info", "You set template to \"$set_template\" but we use only local templates and we have not this template - ignore it");
                }
            }
            else {
                debug_print("warning", "Cannot get local template list - ignore custom template set");
            }
        }
        else {
            $ostemplate = $set_template;
        }
    }
    unless ( $ostemplate) {
        $ostemplate = check_and_change_ostemplate($ct_config_repair->{'OSTEMPLATE'});
    }
    $text_for_json .= qq/"ostemplate":"$ostemplate",/;

    if ( $ostemplate eq $ct_config_repair->{'OSTEMPLATE'} ) {
        debug_print("info", "Container have ostemplate \"$ostemplate\" and we use it");
    }
    else {
        debug_print("info", "Container have ostemplate \"$ct_config_repair->{'OSTEMPLATE'}\", but we use \"$ostemplate\" for repair");
    }

    $ct_config_repair->{'OSTEMPLATE'} = $ostemplate; 
    $ct_config_repair->{'HOSTNAME'} = "repair.".$ct_config_repair->{'HOSTNAME'};
    $ct_config_repair->{'VE_ROOT'} = "/vz/root/\$VEID";
    $ct_config_repair->{'VE_PRIVATE'} = "/vz/private/\$VEID";
    $ct_config_repair->{'DISABLED'} = "no";
    $ct_config_repair->{'ONBOOT'} = "no";
    $ct_config_repair->{'DISKSPACE'} = "2G:2G";
    $ct_config_repair->{'DISKINODES'} = "131072:131072";
    
    debug_print("info", "Create repair container config file $config_file");

    my $open_config_result = open my $config_file_handle, ">", $config_file;
    if ( not $open_config_result ) {
        debug_print("error", "Cannot open to write $config_file: $!");
        print_json(qq/{"error_message":"Cannot open to write $config_file: $!"}/) if $json;
        exit 1;
    }

    for my $parameter ( keys %$ct_config_repair ) {
        print $config_file_handle "$parameter=\"$ct_config_repair->{$parameter}\"\n";
    }

    close $config_file_handle;

    debug_print("info", "Run create container $ctid", "info");
    my $result = `$vzctl create $ctid 2>&1`;
    if ($?) {
        $result =~ s/\n/\|/g;
        debug_print("error", "Cannot create repair container whith errors - $result");
        print_json(qq/{"error_message":"Cannot create repair container"}/) if $json;
        exit 1;
    }
    debug_print("info", "Repair container whith CTID $ctid created successfull");
    
    return 1;
}

sub check_and_change_ostemplate {
    my $ostemplate = shift;

    #for our ispmanager templates
    $ostemplate =~ s/-isplite(\d+)?//;
    $ostemplate =~ s/-isppro(\d+)?//;

    #for our fastpanel templates
    $ostemplate =~ s/-fastpanel//;
    $ostemplate = "debian-7.0-x86_64" if $ostemplate =~ /debian-7-x86_64/;

    #for unsupported ostempltes
    if ( $ostemplate !~ /^(centos-(5|6|7)|debian-(6|7)|ubuntu-(12\.04|14\.04))/ ) {
        $ostemplate = "debian-7.0-x86_64";
    }
    return $ostemplate;
}

sub pwgen {
    my $count = shift;
    my $result = "";
    my @symbols;
    push @symbols, $_ foreach "a".."z";
    for ( 1..$count ) {
        $result .= $symbols[rand($#symbols)];
    }
    return $result;
}

sub get_password_line {
    my $ctid = shift;
    my $shadow_file = "/vz/root/$ctid/repair/etc/shadow";
    
    my $open_shadow_file_result = open my $shadow_handler, "<", $shadow_file;
    if ( not $open_shadow_file_result ) {
        debug_print("warning", "We cannot open \"$shadow_file\": $!");
        return 0;
    }

    while ( my $line = <$shadow_handler> ) {
        if ( $line =~ /^root:/ ) {
            close $shadow_handler;
            return $line;
        }
    }
    close $shadow_handler;
    return 0;
}

sub set_passwd_by_line {
    my $ctid = shift;
    my $password_line = shift;
    my @shadow;
    my $shadow_file = "/vz/root/$ctid/etc/shadow";

    my $open_shadow_file_result = open my $shadow_handler, "<", $shadow_file;
    if ( not $open_shadow_file_result ) {
        debug_print("warning", "We cannot open \"$shadow_file\": $!");
        return 0;
    }

    while ( my $line = <$shadow_handler> ) {
        if ( $line =~ /^root:/ ) {
            push @shadow, $password_line;
        }
        else {
            push @shadow, $line;
        }
    }
    close $shadow_handler;

    $open_shadow_file_result = open $shadow_handler, ">", $shadow_file;
    if ( not $open_shadow_file_result ) {
        debug_print("warning", "We cannot open to write \"$shadow_file\": $!");
        return 0;
    }

    for my $line ( @shadow ) {
        print $shadow_handler $line;
    }

    close $shadow_handler;

    return 1;
}

sub set_our_password {
    my $ctid = shift;
    my $password = shift;

    my $result = `$vzctl set $ctid --userpasswd "root:$password" --save 2>&1`;
    if($?) {
        $result =~ s/\n/\|/g;
        debug_print("warning", "We cannot set root passwd to $ctid whith error - $result! Set password manual, please");
    }
    else {
        debug_print("info", "Password to $ctid set correctly");
    }

    return 1;
}

sub start_repair_for_ctid {
    my $ctid = shift;

    # Get config from main container
    $ct_config = parse_ct_config_to_hash($ctid);
    if ( ref $ct_config ne 'HASH' ) {
        debug_print("error", "We cannot parse $ctid config!");
        print_json(qq/{"error_message":"We cannot parse $ctid config!"}/) if $json;
        exit 1;
    }

    # If repair already created?
    my $new_ctid_status = get_ctid_status($repair_ctid);
    if ( $new_ctid_status =~ / exist / ) {
        debug_print("error", "Container whith repair ctid $repair_ctid already exist! Stop repair or destroy it!");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"Container whith repair ctid $repair_ctid already exist! Stop repair or destroy it!"}/) if $json;
        exit 1;
    }

    # Create repair container
    debug_print("info", "Start create repair container whith ctid $repair_ctid", "info");
    $text_for_json .= qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,/;
    create_repair_container($repair_ctid); 


    # Stop main container
    if ($is_ct_running) {
        debug_print("info", "Container $ctid is running - stop it");
        my $result = `$vzctl stop $ctid 2>&1`;
        if ($?) {
            $result =~ s/\n/\|/g;
            debug_print("error", "We cannot stop container $ctid whith error - $result! Stop it manual");
            print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"We cannot stop container $ctid"}/) if $json;
            # TODO add destroy repair container?
            exit 1;
        }
        debug_print("info", "Container $ctid is stopped now");
    }

    #Disable start main container
    debug_print("info", "Disabled container $ctid");
    my $result = `$vzctl set $ctid --disabled yes --save 2>&1`;
    if ($?) {
        $result =~ s/\n/\|/g;
        debug_print("warning", "We cannot disabled container $ctid whith error - $result! Please do it manual");
    }

    #Start repair container
    debug_print("info", "Start repair container");
    $result = `$vzctl start $repair_ctid 2>&1`;
    if ($?) {
        $result =~ s/\n/\|/g;
        debug_print("error", "We cannot start repair container $repair_ctid whith error - $result!");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"We cannot start repair container"}/) if $json;
        exit 1;
    }
    debug_print("info", "Start $repair_ctid - OK");

    #Create /repair/ dir and mount disk from main container to repair
    debug_print("info", "Create /repair/ on $repair_ctid");
    my $mkdir_result = mkdir "/vz/root/$repair_ctid/repair/";
    if ( not $mkdir_result ) {
        debug_print("error", "We cannot create \"/vz/root/$repair_ctid/repair/\": $!");
        print_json(qq({"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message": "We cannot create /vz/root/$repair_ctid/repair/"})) if $json;
        exit 1;
    }
    debug_print("info", "Mount $ctid disk to /repair/");
    my $ct_private_path = $ct_config->{'VE_PRIVATE'};
    $ct_private_path =~ s/\$VEID/$ctid/;
    $result = `$ploop mount -m /vz/root/$repair_ctid/repair/ $ct_private_path/root.hdd/DiskDescriptor.xml 2>&1`;
    if ($?) {
        $result =~ s/\n/\|/g;
        debug_print("error", "We cannot mount disk from $ctid to /vz/root/$repair_ctid/repair/ whith error - $result!");
        print_json(qq({"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message": "We cannot mount disk from $ctid to /vz/root/$repair_ctid/repair/"})) if $json;
        exit 1;
    }

    #Add chroot-prepare
    if ( add_chroot_prepare($repair_ctid) ) {
        debug_print("info", "Add chroot-prepare script - ok");
    }
    else {
        debug_print("warning", "Add chroot-prepare script - failed");
    }

    #Add custom-motd
    if ( add_custom_motd($repair_ctid) ) {
        debug_print("info", "Add custom motd - ok");
    }
    else {
        debug_print("warning", "Add custom motd - failed");
    }

    #Set root passwd to repair container
    if ($password) {
        if ( $password eq "rand" ){
            $password = pwgen(16);
            debug_print("info", "You set \"rand\" as password - use random passwd \"$password\"");
            $text_for_json .= qq/"password":"$password",/;
        }
        else {
            #Check password and get only a-z A_Z 0-9 and _ symbols
            $password =~ s/[^a-zA-Z0-9_]//g;
            debug_print("info", "We use your password \"$password\"");
            $text_for_json .= qq/"password":"$password",/;
        }
        set_our_password($repair_ctid,$password);
    }
    else {
        #Set password from main container by default (without password param)
        my $password_line = get_password_line($repair_ctid);
        if ( $password_line eq "0" ) {
            $password = pwgen(16);
            debug_print("warning", "We cannot get old password - use random password \"$password\"");
            $text_for_json .= qq/"password":"$password",/;
            set_our_password($repair_ctid,$password);
        }
        else {
            if ( set_passwd_by_line($repair_ctid,$password_line) ) {
                debug_print("info", "We correctly set old password to repair container");
                $text_for_json .= qq/"password":"",/;
            }
            else {
                $password = pwgen(16);
                debug_print("warning", "We cannot set old password to repair container - use random password \"$password\"");
                set_our_password($repair_ctid,$password);
                $text_for_json .= qq/"password":"$password",/;
            }
        }
    }

    debug_print("info", "Start repair whith ctid $repair_ctid finished correctly. Do not forget stop repair, when it not need!");
    $text_for_json .= qq/"repair_enabled":true,"error_message":""}/;
    print_json($text_for_json) if $json;
    #print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid, "repair_enabled": true,"error_message":""}/) if $json;
    if($debug) {
        print "\n";
        print `$vzlist $ctid $repair_ctid`;
        print "\n";
    }
    exit 0;
}

sub get_repair_status_for_ctid {
    my $ctid = shift;
    my $new_ctid_status = get_ctid_status($repair_ctid);
    if ( $new_ctid_status =~ / exist / ) {
        debug_print("info", "Repair must be enabled -container whith repair ctid $repair_ctid already exist!");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"repair_enabled":true}/) if $json;
        if($debug) {
            print "\n";
            print `$vzlist $ctid $repair_ctid`;
            print "\n";
        }
        exit 0;
    }
    else {
        debug_print("info", "Repair not enable  - we have not container whith repair ctid $repair_ctid");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"repair_enabled":false}/) if $json;
        exit 0;
         
    }
}

sub stop_repair_for_ctid {
    my $ctid = shift;
    #Get actual status of repair container
    my $new_ctid_status = get_ctid_status($repair_ctid);

    if ( $new_ctid_status =~ / exist / ) {

        #Try to umount main container disk from directory
        debug_print("info", "Umount $ctid disk from /repair/");
        my $result = `/bin/umount -l /vz/root/$repair_ctid/repair/ 2>&1`;
        if ( $? ) {
            $result =~ s/\n/\|/g;
            debug_print("warning", "We cannot umount /vz/root/$repair_ctid/repair/ directory");
        }
        
        #Stop if repair container runnig
        if ( $new_ctid_status =~ / running$/ ) {
            debug_print("info", "Stop repair container whith ctid $repair_ctid");
            my $result = `$vzctl stop $repair_ctid 2>&1`;
            if ($?) {
                $result =~ s/\n/\|/g;
                debug_print("error", "We cannot stop $repair_ctid whith error - $result!");
                print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"We cannot stop repair container"}/) if $json;
                exit 1;
            }
        }

        #Try to umount main container disk from ploop device
        my $ct_config = parse_ct_config_to_hash($ctid);
        my $ct_private_path = "/vz/private/$ctid";
        if (ref $ct_config ne 'HASH') {
            debug_print("error", "We cannot parse ctid config - set private path as $ct_private_path");
        }
        else {
            $ct_private_path = $ct_config->{'VE_PRIVATE'};
            $ct_private_path =~ s/\$VEID/$ctid/;
        }
        debug_print("info", "Umount $ctid disk from ploop device");
        $result = `$ploop umount $ct_private_path/root.hdd/DiskDescriptor.xml 2>&1`;
        if ($?) {
            $result =~ s/\n/\|/g;
            #It is ok - already not mount
            if ( $result =~ /No such file or directory/ or $result =~ /Unable to find ploop device by/) {
                debug_print("warning", "$ct_private_path/root.hdd/DiskDescriptor.xml not mounted");
            }
            else {
                #Realy fail to umount 
                debug_print("error", "We cannot umount $ctid disk via $ploop whith error - $result!");
            }
        }

        #Destroy! Destroy! Destroy!
        debug_print("info", "Destroy repair container $repair_ctid");
        #impossible exception
        if ( $repair_ctid < $ctid_seek ) {
            debug_print("error", "We have wrong repair ctid - not destroy container!");
            print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"We have wrong repair ctid - not destroy container"}/) if $json;
            exit 1;
        }
        $result = `$vzctl destroy $repair_ctid 2>&1`;
        if ($?) {
            $result =~ s/\n/\|/g;
            debug_print("error", "We cannot destroy $repair_ctid whith $result! Please destroy it manual!");
            print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"error_message":"We cannot destroy repair container"}/) if $json;
            exit 1;
        }

        #Enable start to main config back
        $result = `$vzctl set $ctid --disabled no --save 2>&1`;
        debug_print("info", "Enabled container $ctid");
        if ($?) {
            $result =~ s/\n/\|/g;
            debug_print("warning", "We cannot enabled container $ctid whith error - $result! Please do it manual");
        }

        debug_print("info", "Repair stopped successful - you can start $ctid if it need");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"repair_enabled":false,"error_message":""}/) if $json;
        if($debug) {
            print "\n";
            print `$vzlist $ctid `;
            print "\n";
        }
        exit 0;
   }
   else {
       debug_print("info", "Repair not enable  - we have not container whith repair ctid $repair_ctid");
        print_json(qq/{"ctid":$ctid,"repair_ctid":$repair_ctid,"repair_enabled":false,"error_message":""}/) if $json;
       exit 0;
   }


}

sub add_chroot_prepare {
    my $ctid = shift;

    my $chroot_file = "/vz/root/$ctid/bin/chroot-prepare";

    open my $chroot_file_handle, ">", $chroot_file or return 0;
    my $chroot_prepare_script = << 'EOF';
#!/usr/bin/perl

use strict;
use warnings;

use Term::ANSIColor;

my $mount_point = "/repair";

my @mount_dirs = (
    "/dev/",
    "/proc/",
    "/sys/",
);

if ( defined $ARGV[0] ) {
    $mount_point = $ARGV[0];
    chomp $mount_point;
    $mount_point =~ s|/$||;
}

die "We have not directory $mount_point\n" if  not -d $mount_point;


for my $directory ( @mount_dirs ) {
    print "Mount $directory to ${mount_point}$directory\t\t";
    my $result = `mount --bind $directory ${mount_point}$directory 2>&1`;
    if ( $? ) {
        print color 'bold red';
        print "FAIL\n";
        print color 'reset';
        print $result;
        next;
    }
    print color 'bold green';
    print "OK\n";
    print color 'reset';
}
EOF
;
    print $chroot_file_handle $chroot_prepare_script;
    close $chroot_file_handle;
    chmod "755", $chroot_file;
    return 1;
}

sub add_custom_motd {
    my $ctid = shift;

    my $motd_file = "/vz/root/$ctid/etc/motd";
    open my $motd_file_handle, ">", $motd_file or return 0;
    my $motd_file_content = << 'EOF';

-------------------------------------------------------------------

  Welcome to the FastVPS Repair System.

  This Repair System is based on template from your server.
  Your file-system available in /repair/

  Please, note, that all changes in Repair System will be lost
  after reboot.

  Best Regards, FastVPS.

-------------------------------------------------------------------

EOF
;
    print $motd_file_handle $motd_file_content;
    close $motd_file_handle;
    chmod "644", $motd_file;
    return 1;
}

sub print_json {
    use utf8;
    my $text_for_json = shift;
    utf8::encode($text_for_json);
    print $text_for_json;
}

sub get_local_templates_list {
    my @local_templates_list;

    my $vztmpl_output = `$vztmpl_dl --list-local 2>&1`;
    if ($?) {
        $vztmpl_output =~ s/\n/ | /g;
        debug_print("warning", "Error - cannot get list local templates via vztmpl-dl - $vztmpl_output");
        return ();
    }
    push @local_templates_list, $_ for ( split /\n/, $vztmpl_output);

    return @local_templates_list;
}

__END__

=head1 NAME

vzrepair.pl - script to start/stop repair for container(like PCS repair)

=head1 SYNOPSIS

vzrepair.pl  [ --help ] < --ctid CTID > [ --start | --stop | --status ] 

=head1 OPTIONS

=over 8

=item B<--help>

Print help message

=item B<--ctid>

Container CTID

=over 12

=item B<--start>

Start repair - stop container if it running, create and start repair container, mount root.hdd from main container to /repair/

=over 12

=item B<--password>

Used only whith --start . Set password to repair container. By default(without param) - use password from main container. If set "rand" - set random pass.

=item B<--template>

Used only whith --start . Set maunal template for repair container. Use $set_only_local_templates variable, for use it only with local templates or not

=back

=item B<--stop>

Stop repair - stop and delete repair container

=item B<--status>

Show status - we have repair container for this CTID or not

=item B<--silent>

Not show debug output(json output be print)

=item B<--json>

Print json message, use it with --silent, to have only json output

=back

=back

=head1 DESCRIPTION

We use 1000000000+ number for repair CTIDs.

Repair CTID = CTID + 1000000000. 

Hostname changed to "repair.HOSTNAME" on repair container.

=cut
