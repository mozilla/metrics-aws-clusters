## aws emr create-cluster --ami-version "3.6.0" --log-uri s3://sguhaemrlogs --name "MyCluster" --enable-debugging --ec2-attributes KeyName="sguhaMozillaEast" --instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m3.xlarge InstanceGroupType=CORE,InstanceCount=1,InstanceType=m3.xlarge --bootstrap-action Path=s3://elasticmapreduce/bootstrap-actions/configure-hadoop,Args=["-m","mapred.map.child.java.opts=-Xmx1024m","-m","mapred.reduce.child.java.opts=-Xmx1024m"] 


## pip install awscli
## or on hala, see bundled install: http://docs.aws.amazon.com/cli/latest/userguide/installing.html#install-with-pip
## chmod 400 your PEM files
## remove / unset Environment AWS_SEC* variables
## run aws emr create-default-roles if you're going to use default roles
## create keys in same region as cluster
## use ssh-add to add your key.pem file, so no need for --key-pair-file

require(rjson)
require(data.table)

.checked <- function(e,s){
    y <- substitute(e,env=parent.frame())
    tryCatch({
        z <- eval(y)
        if(length(z)==0 || is.null(z)) s else z
        }, error=function(err) s)
}

print.awsEmrCluster <- function(y){
    creation.time       <- .checked(as.POSIXct(y$Cluster$Status$Timeline$CreationDateTime,origin="1970-01-01"),NA)
    ready.time          <- .checked(as.POSIXct(y$Cluster$Status$Timeline$ReadyDateTime,origin="1970-01-01"),NA)
    state               <- .checked(y$Cluster$Status$State,NA)
    statemsg            <- .checked(y$Cluster$Status$StateChangeReason$Message,NA)
    idd                 <- .checked(y$Cluster$Id,NA)
    nn                  <- .checked(y$Cluster$Name,NA)
    MasterPublicDnsName <- .checked(y$Cluster$MasterPublicDnsName,NA)
    ig                  <- y$Cluster$InstanceGroups
    if(!is.null(ig)){
        totalInstance   <- sum(unlist(lapply(ig, function(k){
            .checked(k$RunningInstanceCount,0)
        })))
    }else totalInstance <- 0
    o                   <- data.table(id=idd, name=nn, created=creation.time, started=ready.time, state=state, status=statemsg, publicdns=MasterPublicDnsName,
                           instances=totalInstance, nhrs=.checked(y$Cluster$NormalizedInstanceHours, NA))
    print(o)
}
             
emrDescribeCluster <- function(clusterid){
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }else     if(is(clusterid, "awsEmrCluster")){
        clusterid <- clusterid$Cluster$Id
    }

    y <- tryCatch( fromJSON(paste(system(sprintf("aws emr describe-cluster --cluster-id %s",clusterid),intern=TRUE),collapse="\n")), error=function(s){
        cat(sprintf("emrDescribeCluster: problem parsing output\n"))
        NULL
    })
    y$hadoopPort <- list(rm=9026,nn=9101, rstudio=8787)
    class(y) <- append(class(y),"awsEmrCluster")
    return(y)
}

## ls | parallel -j0 -N2 s3cmd put {1} s3://somes3bucket/dir1/
## hadoop s3n://awsaccesskey:awssecrectkey@somebucket/mydata/ distcp hdfs:///data/
emrMakeCluster <- function(name=sprintf("%s's EMR Cluster",Sys.getenv("USER")), instances=3,loguri,keyname,bootstrap=NULL){
    ## Example
    ## emrMakeCluster(instances=2, loguri="s3://sguhaemrlogs", keyname="sguhaMozillaEast")
    ## keyName must be created in the same region as region specifed via aws configure
    if(instances<2) stop("instances needs to be at least 2: one for the master and one for the core node")
    s <- sprintf('aws emr create-cluster --ami-version "3.6.0" --log-uri %s --name "%s" --enable-debugging --ec2-attributes KeyName=%s --instance-groups InstanceGroupType=MASTER,InstanceCount=1,InstanceType=m3.xlarge InstanceGroupType=CORE,InstanceCount=%s,InstanceType=m3.xlarge --bootstrap-action Path=s3://elasticmapreduce/bootstrap-actions/configure-hadoop,Args=["-m","mapred.map.child.java.opts=-Xmx1024m","-m","mapred.reduce.child.java.opts=-Xmx1024m"] --bootstrap-action Path="s3n://rhipeemr/kickstartrhipe.sh" --steps Type=CUSTOM_JAR,Name=CustomJAR,ActionOnFailure=CONTINUE,Jar=s3://elasticmapreduce/libs/script-runner/script-runner.jar,Args=["s3://rhipeemr/final.step.sh"] ',
                 loguri,name,keyname,instances-1)
    if(!is.null(bootstrap)){
        s <- sprintf("%s --bootstrap-action Path=\"%s\"", bootstrap)
    }
    y <- tryCatch({
        z <- fromJSON(paste(system(s,intern=TRUE),collapse="\n"))
        return(z$ClusterId)
    } , error=function(s){
        print(s)
        cat(sprintf("emrMakeCluster: problem parsing output\n"))
        NULL
    })
}

emrWaitForStart <- function(clusterid,mon.sec=5){
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }
    while(TRUE){
        y <- emrDescribeCluster(clusterid)
        if(y$Cluster$Status$State %in% c("WAITING","FAILED","TERMINATED","TERMINATING","TERMINATED_WITH_ERRORS")) break
        Sys.sleep(mon.sec)
    }
    y
}
   
emrKillCluster <- function(clusterid){
    if(is(clusterid, "awsEmrCluster")){
        clusterid <- clusterid$Cluster$Id
    }
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }
    tryCatch({system(sprintf("aws emr terminate-clusters --cluster-id %s",paste(clusterid,collapse=" ")),intern=TRUE);TRUE},error=function(e) FALSE)
}

emrSendFile <- function(clusterid, src, dest=NULL,keypair){
    if(is(clusterid, "awsEmrCluster")){
        clusterid <- clusterid$Cluster$Id
    }
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }
    s <- sprintf("aws emr put --cluster-id %s --key-pair-file %s --src %s", clusterid, keypair, src)
    if(!is.null(dest)) s <- sprintf("%s --dest %s", s, dest)
    tryCatch({system(s); TRUE},error=function(e) {print(e); FALSE})
}

emrGetFile <- function(clusterid, src, dest=NULL,keypair){
    if(is(clusterid, "awsEmrCluster")){
        clusterid <- clusterid$Cluster$Id
    }
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }
    s <- sprintf("aws emr get --cluster-id %s --key-pair-file %s --src %s", clusterid, keypair, src)
    if(!is.null(dest)) s <- sprintf("%s --dest %s", s, dest)
    tryCatch({system(s); TRUE},error=function(e) {print(e); FALSE})
}

emrRemoteCMD <- function(clusterid, cmd,keypair){
    if(is(clusterid, "awsEmrCluster")){
        clusterid <- clusterid$Cluster$Id
    }
    if(!grepl("^(j\\-)",clusterid)) {
        clusterid <- sprintf("j-%s",clusterid)
    }
    s <- sprintf("aws emr get --cluster-id %s --key-pair-file %s --command %s", clusterid, keypair, cmd)
    tryCatch({system(s); TRUE},error=function(e) {print(e); FALSE})
}


emrListClusters <- function(){
     y <- fromJSON(paste(system("  aws emr list-clusters", intern=TRUE),collapse="\n"))
     l <- lapply(y$Clusters,function(y){
         z <- list(); z$Cluster <- y
         z$hadoopPort <- list(rm=9026,nn=9101, rstudio=8787)
         class(z) <- append(class(z),"awsEmrCluster")
         z
     })
     l[ order(unlist(lapply(l, function(k) k$Cluster$Status$Timeline$CreationDateTime)),decreasing=TRUE)]
 }
