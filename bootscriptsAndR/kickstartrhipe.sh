while [ $# -gt 0 ]; do
	case "$1" in
		--public-key)
			shift
			PUBLIC_KEY=$1
			;;
		--timeout)
			shift
			TIMEOUT=$1
			;;
		-*)
			# do not exit out, just note failure
			error_msg "unrecognized option: $1"
			;;
		*)
			break;
			;;
	esac
	shift
done

if [ -n "$PUBLIC_KEY" ]; then
	echo $PUBLIC_KEY >> $HOME/.ssh/authorized_keys
fi

# Schedule shutdown at timeout (minutes)
if [ ! -z $TIMEOUT ]; then
	sudo shutdown -h +$TIMEOUT&
fi

export MYHOME=/home/hadoop

## What i can yum, i shall yum
sudo yum -y install git emacs tbb tbb-devel jq tmux libffi-devel htop
## force python 2.7
sudo rm /usr/bin/python /usr/bin/pip
sudo ln -s /usr/bin/python2.7 /usr/bin/python
sudo ln -s /usr/bin/pip-2.7 /usr/bin/pip
sudo sed -i '1c\#!/usr/bin/python2.6' /usr/bin/yum



cd $MYHOME
mkdir -p proto
aws s3 sync s3://mozillametricsemrscripts/proto/25 $MYHOME/proto/
sudo yum -y install $MYHOME/proto/protobuf-2.5.0-16.1.x86_64.rpm
sudo yum -y install $MYHOME/proto/protobuf-compiler-2.5.0-16.1.x86_64.rpm
sudo yum -y install $MYHOME/proto/protobuf-devel-2.5.0-16.1.x86_64.rpm

## Prepare Hadoop Related variables
cd $MYHOME
echo 'export R_LIBS=/usr/local/rlibs' | sudo tee -a /etc/bashrc
echo 'export HADOOP=/home/hadoop' | sudo tee -a /etc/bashrc
echo 'export HADOOP_HOME=/home/hadoop'  | sudo tee -a /etc/bashrc
echo 'export HADOOP_CONF_DIR=/home/hadoop/conf/' | sudo tee -a /etc/bashrc
echo 'export RHIPE_HADOOP_TMP_FOLDER=/tmp/' | sudo tee -a /etc/bashrc
echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig' | sudo tee -a /etc/bashrc
echo "export HADOOP_LIBS=`hadoop classpath | tr -d '*'`" | sudo tee -a /etc/bashrc

#sudo sed -i "s/.*PasswordAuthentication no.*/PasswordAuthentication yes/"  /etc/ssh/sshd_config
#sudo service  sshd restart

## Create the user and install rserver
## this runs on 8787
for auser in metrics dzeber cchoi aalmossawi bcolloran rweiss jjensen hulmer sguha joy
do
    sudo useradd -m ${auser}
    echo "${auser}:${auser}" | sudo chpasswd
    echo ${auser} | su -c  'mkdir $HOME/.ssh; chmod 700 $HOME/.ssh' ${auser}
    echo ${auser} | su -c  "echo \"${PUBLIC_KEY}\" >> /home/${auser}/.ssh/authorized_keys"  ${auser} 
    sudo chmod 600 /home/${auser}/.ssh/authorized_keys
done

sudo yum -y install openssl098e # Required only for RedHat/CentOS 6 and 7
aws s3 cp s3://mozillametricsemrscripts/rstudio/rstudio-server-0.98.1102-x86_64.rpm $MYHOME/
sudo yum -y install --nogpgcheck $MYHOME/rstudio-server-0.98.1102-x86_64.rpm
sudo chmod aou=rw /etc/rstudio/rsession.conf 
sudo  echo "r-libs-user=/usr/local/rlibs/" >> /etc/rstudio/rsession.conf 


## Setup Emacs
mkdir -p $MYHOME/site-lisp
aws s3 cp s3://mozillametricsemrscripts/ess/ess-15.03.zip $MYHOME/site-lisp/
cd $MYHOME/site-lisp/
unzip ess-15.03.zip
(
cat <<'EOF'
(load "~/site-lisp/ess-15.03/lisp/ess-site")
EOF
)> $HOME/.emacs
cd $MYHOME

## Now download the archives of /usr/local/share/rlibraries/ which
## is the archive the packages i installed 

aws s3 cp s3://mozillametricsemrscripts/rlibraries/rlibs.tgz $MYHOME/
sudo mv $MYHOME/rlibs.tgz /usr/local/
cd /usr/local
sudo tar xfz rlibs.tgz --strip-components=2 
sudo chmod -R 4777 /usr/local/rlibs/

aws s3 cp  s3://mozillametricsemrscripts/rlibraries/Rhipe_0.75.1.5_hadoop-2.tar.gz $MYHOME/
cd $MYHOME
R CMD INSTALL -l /usr/local/rlibs/ $MYHOME/Rhipe_0.75.1.5_hadoop-2.tar.gz 



## Setup environment variables

source  /etc/bashrc

## Put the following into .Renviron
echo "HADOOP=${HADOOP}" | sudo  tee -a /usr/lib64/R/etc/Renviron 
echo "HADOOP_HOME=${HADOOP_HOME}" | sudo  tee -a /usr/lib64/R/etc/Renviron 
echo "HADOOP_CONF_DIR=${HADOOP_CONF_DIR}" | sudo  tee -a /usr/lib64/R/etc/Renviron 
echo "RHIPE_HADOOP_TMP_FOLDER=${RHIPE_HADOOP_TMP_FOLDER}" | sudo tee -a /usr/lib64/R/etc/Renviron 
echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}" | sudo tee -a /usr/lib64/R/etc/Renviron 
echo "HADOOP_LIBS=${HADOOP_LIBS}"| sudo  tee -a /usr/lib64/R/etc/Renviron 
echo "R_LIBS=/usr/local/rlibs"| sudo  tee -a /usr/lib64/R/etc/Renviron 
sudo chmod -R 777 /mnt


################################################################################
## Only master needs to do this
## 1. Start Rstudio
## quoting EOF turns of substitution
################################################################################
(
cat <<'EOF'
require 'emr/common'
instance_info = Emr::JsonInfoFile.new('instance')
$is_master =  instance_info['isMaster'].to_s == 'true' 
print $is_master
EOF
) > /tmp/isThisMaster

(
cat <<'EOF'
require 'emr/common'
instance_info = Emr::JsonInfoFile.new('instance')
$is_running = instance_info['isRunningResourceManager'].to_s == 'true' 
print $is_running
EOF
) > /tmp/isJTRunning

isMaster=`ruby /tmp/isThisMaster`
if [ $isMaster = "true" ]; then
    echo "Running In Master"
    sudo rstudio-server restart
fi

Y1=`Rscript -e 'cat(strsplit(readLines("/home/hadoop/.aws/config")[2],"=[ ]+")[[1]][[2]])'`
Y2=`Rscript -e 'cat(strsplit(readLines("/home/hadoop/.aws/config")[3],"=[ ]+")[[1]][[2]])'`
(
    
cat <<EOF

export AWS_ACCESS_KEY_ID=${Y1}
export AWS_SECRET_ACCESS_KEY=${Y2}

EOF
) >> $MYHOME/.bashrc

cd $MYHOME

## BOOM!
