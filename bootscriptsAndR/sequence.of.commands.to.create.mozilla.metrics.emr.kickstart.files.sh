## This is meant to be run using AMI 3+ which used Hadoop 2.4 (YARN based MR)
sudo yum -y install git emacs  
cd $HOME


## If the following files cannot be found, download from the S3 bucket (see below)
wget ftp://ftp.pbone.net/mirror/ftp5.gwdg.de/pub/opensuse/repositories/home:/kalyaka/CentOS_CentOS-6/x86_64/protobuf-2.5.0-16.1.x86_64.rpm
wget ftp://ftp.pbone.net/mirror/ftp5.gwdg.de/pub/opensuse/repositories/home:/kalyaka/CentOS_CentOS-6/x86_64/protobuf-devel-2.5.0-16.1.x86_64.rpm
wget ftp://ftp.pbone.net/mirror/ftp5.gwdg.de/pub/opensuse/repositories/home:/kalyaka/CentOS_CentOS-6/x86_64/protobuf-compiler-2.5.0-16.1.x86_64.rpm
sudo rpm -ivh protobuf-2.5.0-16.1.x86_64.rpm
sudo rpm -ivh protobuf-compiler-2.5.0-16.1.x86_64.rpm
sudo rpm -ivh protobuf-devel-2.5.0-16.1.x86_64.rpm

    
## Installed protobuf 2.5
wget https://protobuf.googlecode.com/files/protobuf-2.5.0.tar.bz2
tar  jxvf protobuf-2.5.0.tar.bz2
cd protobuf-2.5.0
./configure && make -j3
sudo make install
cd ..
echo '/usr/local/lib' | sudo tee -a  /etc/ld.so.conf.d/protobuf.conf
sudo ldconfig 

## Install R packages
sudo mkdir -p /usr/local/rlibs
sudo chmod -R 4777 /usr/local/rlibs/
R -e 'for(x in c("rJava","roxygen2")){ install.packages(x,lib="/usr/local/rlibs/",repos="http://cran.cnr.Berkeley.edu",dep=TRUE)}'
R -e 'for(x in c("Hmisc","rjson","data.table","zoo","latticeExtra")){ install.packages(x,lib="/usr/local/rlibs/",repos="http://cran.cnr.Berkeley.edu",dep=TRUE)}'
wget https://github.com/saptarshiguha/terrific/releases/download/1.4/rterra_1.4.tar.gz
R CMD INSTALL -l /usr/local/rlibs/ /home/hadoop/rterra_1.4.tar.gz
sudo chmod -R 4777 /usr/local/rlibs/


## BASH PROFILE
echo 'export HADOOP=/home/hadoop' | sudo tee -a /etc/bashrc
echo 'export HADOOP_HOME=/home/hadoop'  | sudo tee -a /etc/bashrc
echo 'export HADOOP_CONF_DIR=/home/hadoop/conf/' | sudo tee -a /etc/bashrc
echo 'export RHIPE_HADOOP_TMP_FOLDER=/tmp/' | sudo tee -a /etc/bashrc
echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig' | sudo tee -a /etc/bashrc
echo "export HADOOP_LIBS=`hadoop classpath | tr -d '*'`" | sudo tee -a /etc/bashrc

. /etc/bashrc

## Now compile RHIPE for Apache Amazon Hadoop
cd $HOME
wget ftp://apache.mirrors.pair.com//ant/binaries/apache-ant-1.9.4-bin.zip
unzip apache-ant-1.9.4-bin.zip
mv apache-ant-1.9.4 ant
git clone git://github.com/tesseradata/RHIPE.git
cd RHIPE
$HOME/ant/bin/ant build-distro -Dhadoop.version=hadoop-2

R CMD INSTALL -l /usr/local/rlibs/ /home/hadoop/RHIPE/Rhipe_0.75.1.5_hadoop-2.tar.gz

## Installs rstudio . If the following rpm file can't be found, download
## from our S3 bucket (see below)
# sudo useradd -m metrics
# echo "metrics:metrics" | sudo chpasswd
# sudo chmod aou=rw /etc/rstudio/rsession.conf 
# sudo -i echo "r-libs-user=/usr/local/rlibs/" >> /etc/rstudio/rsession.conf 
# sudo yum -y install openssl098e # Required only for RedHat/CentOS 6 and 7
# wget http://download2.rstudio.org/rstudio-server-0.98.1102-x86_64.rpm
# sudo yum -y install --nogpgcheck rstudio-server-0.98.1102-x86_64.rpm
# sudo rstudio-server restart


## Prepare the kickstart files on S3 for when the Cluster starts

## 0. This was done once
aws s3 mb s3://mozillametricsemrscripts/rstudio
aws s3 mb s3://mozillametricsemrscripts/proto/25

## 1. Copy these files to S3 so the mozillametrics-kickstart.sh can download them
aws s3 cp /home/hadoop/protobuf-2.5.0-16.1.x86_64.rpm s3://mozillametricsemrscripts/proto/25/
aws s3 cp /home/hadoop/protobuf-compiler-2.5.0-16.1.x86_64.rpm s3://mozillametricsemrscripts/proto/25/
aws s3 cp /home/hadoop/protobuf-devel-2.5.0-16.1.x86_64.rpm s3://mozillametricsemrscripts/proto/25/


## 2. Copy rstudio server to S3
aws s3 cp rstudio-server-0.98.1102-x86_64.rpm s3://mozillametricsemrscripts/rstudio/
   
## 3. Ess for R ...
wget http://ess.r-project.org/downloads/ess/ess-15.03.zip
aws s3 cp ess-15.03.zip s3://mozillametricsemrscripts/ess/


## 4. Save the R libraries
tar cvfz rlibs.tgz /usr/local/rlibs/
aws s3 mb s3://mozillametricsemrscripts/rlibraries/
aws s3 cp rlibs.tgz s3://mozillametricsemrscripts/rlibraries/

## 5. From Mark Reid(see email "A copy of s3://telemetry-spark-emr/telemetry.sh")
## April 15, 2015 , the telemety bootstrap script.
aws s3 cp ~/mz/ec2stuff/telemetryspark.sh s3://mozillametricsemrscripts/telemetry/


## 6. Copy kickstarter and final to s3
aws s3 cp ~/mz/ec2stuff/kickstartrhipe.sh s3://mozillametricsemrscripts/
aws s3 cp ~/mz/ec2stuff/final.step.sh s3://mozillametricsemrscripts/


## Test this R code
library(Rhipe)
rhinit()

f <- rhwatch(map=function(a,b){
    rhcollect(1,1)
},
             input=rhfmt(type = "sequence", folder = "s3://mozillametricsemrscripts/fhr/samples/1pct/1/part99", recordsAsText = TRUE),
             output=rhfmt(type = "sequence", folder = "s3://sguhaoutputs/test", recordsAsText = TRUE),read=FALSE)

rhread(f,textual=TRUE)

        

## Example Of Creating a Cluster (with spark)

 # aws emr create-cluster --ami-version "3.6.0" --tags "user=sguha@mozilla.com" --log-uri s3://mozillametricsemrscripts/logs --name "MyCluster1" --enable-debugging --ec2-attributes KeyName="sguhaMozillaEast" --instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m3.xlarge InstanceGroupType=CORE,InstanceCount=1,InstanceType=m3.xlarge --bootstrap-action Path=s3://elasticmapreduce/bootstrap-actions/configure-hadoop,Args=["-m","mapred.map.child.java.opts=-Xmx1024m","-m","mapred.reduce.child.java.opts=-Xmx1024m","-y","yarn.resourcemanager.scheduler.class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fair.FairScheduler"] Path=s3://mozillametricsemrscripts/kickstartrhipe.sh,Args=["--public-key","ssh-dss AAAAB3NzaC1kc3MAAACBANMpnkZXR8tSM/D88euhy+gExt9qKGUd/Rm+qqoIOZtQLgM5VGqmc8wouMCCEU/QCetp2CHha4N1xtWv3oRyhAeLU26XpcZE0fZF7te5CemlwfnVuz1gMlV24BfSy5WOuAHstZTsKfieL3Fyw7LB5XsZ5uICkjirsLNsnnWVFelpAAAAFQDxd8G6dElRtGbtO6g13FlTmBN02QAAAIA/hgvLASzlTY7UQhniCBqwzZaeg+zBgc8B6hdtxkQqmDTV7pj8dnus+R/ZY0Lyjc29u9FB6HUiawuxC0lzWwRmukv0hjXhByujlVaZwFyl6Zw6yyygxceaut+79hc5EXlVdReq6qTc6ufpKpcYYGVTMzEAsTiVGh9CHgfqXEbvYwAAAIAsde9xccPeqPiz9Qxahx4vyh/nCPEeXRaDQgdDy4G9m8kjFztfR/QLoPwe0AlN87HjczCviS7brS6Gm51aorddfbrbWMOOh10ZMTtdNYQu9kQOQPopwVof6Tc8IPyq+ht3yHn/b0kM9YH0Hbxj+D1Ys7EelQljmwJLtuQQPNMFQw== sguha@maya","--timeout","240"] Path=s3://support.elasticmapreduce/spark/install-spark,Args=["-v","1.2.1.a"]  Path=s3://mozillametricsemrscripts/telemetry/telemetryspark.sh  --steps Type=CUSTOM_JAR,Name=CustomJAR,ActionOnFailure=CONTINUE,Jar=s3://elasticmapreduce/libs/script-runner/script-runner.jar,Args=["s3://mozillametricsemrscripts/final.step.sh"] 


## Without Spark (which occupies all dem resources)
aws emr create-cluster --ami-version "3.6.0" --tags "user=sguha@mozilla.com" --log-uri s3://mozillametricsemrscripts/logs --name "MyCluster1" --enable-debugging --ec2-attributes KeyName="sguhaMozillaEast" --instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m3.xlarge InstanceGroupType=CORE,InstanceCount=1,InstanceType=m3.xlarge --bootstrap-action Path=s3://elasticmapreduce/bootstrap-actions/configure-hadoop,Args=["-m","mapred.map.child.java.opts=-Xmx1024m","-m","mapred.reduce.child.java.opts=-Xmx1024m","-y","yarn.resourcemanager.scheduler.class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fair.FairScheduler"] Path=s3://mozillametricsemrscripts/kickstartrhipe.sh,Args=["--public-key","ssh-dss AAAAB3NzaC1kc3MAAACBANMpnkZXR8tSM/D88euhy+gExt9qKGUd/Rm+qqoIOZtQLgM5VGqmc8wouMCCEU/QCetp2CHha4N1xtWv3oRyhAeLU26XpcZE0fZF7te5CemlwfnVuz1gMlV24BfSy5WOuAHstZTsKfieL3Fyw7LB5XsZ5uICkjirsLNsnnWVFelpAAAAFQDxd8G6dElRtGbtO6g13FlTmBN02QAAAIA/hgvLASzlTY7UQhniCBqwzZaeg+zBgc8B6hdtxkQqmDTV7pj8dnus+R/ZY0Lyjc29u9FB6HUiawuxC0lzWwRmukv0hjXhByujlVaZwFyl6Zw6yyygxceaut+79hc5EXlVdReq6qTc6ufpKpcYYGVTMzEAsTiVGh9CHgfqXEbvYwAAAIAsde9xccPeqPiz9Qxahx4vyh/nCPEeXRaDQgdDy4G9m8kjFztfR/QLoPwe0AlN87HjczCviS7brS6Gm51aorddfbrbWMOOh10ZMTtdNYQu9kQOQPopwVof6Tc8IPyq+ht3yHn/b0kM9YH0Hbxj+D1Ys7EelQljmwJLtuQQPNMFQw== sguha@maya","--timeout","240"]  --steps Type=CUSTOM_JAR,Name=CustomJAR,ActionOnFailure=CONTINUE,Jar=s3://elasticmapreduce/libs/script-runner/script-runner.jar,Args=["s3://mozillametricsemrscripts/final.step.sh"] 
