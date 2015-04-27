source("~/prefix.R") ## for email and %format%
library(rjson)
library(data.table)
library(gsubfn)
`%format%` <- function(fmt, list) {
    pat <- "%\\(([^)]*)\\)"
    fmt2 <- gsub(pat, "%", fmt)
    list2 <- list[strapplyc(fmt, pat)[[1]]]
    do.call("sprintf", c(fmt2, list2))
}


isn <- function(s,r=NA) if(is.null(s) || length(s)==0) NA else s
awscommand <- function(cmd){
    fromJSON(paste(system(cmd,intern=TRUE),collapse="\n"))
}
cluster.list <- awscommand("aws emr list-clusters")$Cluster

dateRange <- list(end=Sys.Date(),start=Sys.Date() - 7)
cl.running.or.createdThisWeek <- Map(function(s){
    sinfo <- awscommand(sprintf("aws emr describe-cluster --cluster-id %s", s$Id))
    whenStarted <- as.Date(as.POSIXct(s$Status$Timeline$CreationDateTime,origin="1970-01-01"))
    user <-  isn(Filter(function(so) so$Key=="user",sinfo$Cluster$Tags)) #[[1]]$Value
    user <- if(is.na(user)) "missing-user" else user[[1]]$Value
    list(top=s, detail=sinfo,user=user,when=whenStarted)
    },Filter(function(s){
        whenStarted <- as.Date(as.POSIXct(s$Status$Timeline$CreationDateTime,origin="1970-01-01"))
        x1 <- whenStarted >= dateRange$start
        x2 <- s$Status$State %in% c("WAITING","RUNNNG")
        x1 || x2
    },cluster.list))

clus.table <- rbindlist(Map(function(s){
    user <- isn(s$user)
    current.state <- isn(s$top$Status$State)
    nml.instance.hrs <- isn(s$detail$Cluster$NormalizedInstanceHours)
    crtd.l7days <- isn(s$when>=dateRange$start)
    crt.time <- s$when
    data.table(user=user, currently=current.state, hrs=nml.instance.hrs, created7days=crtd.l7days,crt=crt.time)
}, cl.running.or.createdThisWeek))

## Summary of the report in last 7 days

top <- list()
## Clusters Created: 
top$clusters.created.this.week <- nrow(clus.table)

## Currently Running Clusters:
top$clusters.running.this.week <- sum(clus.table$currently %in% c("WAITING","RUNNG"))

## Number of Users with Running Clusters:
top$num.users.with.running.clusters <-clus.table[currently %in% c("WAITING","RUNNG"), length(unique(user))]
top$users.with.running.clusters <- clus.table[currently %in% c("WAITING","RUNNG"), paste(unique(user),collapse=", ")]
if(top$users.with.running.clusters == "") top$users.with.running.clusters = "there aren't any clusters running"
    
## Cumulative Normalized Instance Hours (of currently running (could
## have been started anytime) and started this week:
top$all.nml.instance.hrs <- sum(clus.table$hrs)

top$oldest.running.cluster <- clus.table[currently %in% c("WAITING","RUNNG"),as.numeric(max(Sys.Date()-crt))]
top$oldest.running.cluster <- if(top$oldest.running.cluster == -Inf) "no cluster running" else sprintf("%s days", top$oldest.running.cluster)

introStr <- "Hello Metrics,

The following is a report of AWS EMR usage for the last 7 days. Your clusters can be managed at: https://hala.metrics.scl3.mozilla.com:8081

Summary
-------

# of clusters created in last 7 days    : %(clusters.created.this.week)d
# of currently running clusters         : %(clusters.running.this.week)d
# of users with running clusters        : %(num.users.with.running.clusters)d
Users with running clusters             : %(users.with.running.clusters)s
# Normalized Instance Hours[1]          : %(all.nml.instance.hrs)d
# age in days of oldest running cluster : %(oldest.running.cluster)s 

[1] http://aws.amazon.com/elasticmapreduce/faqs/

By User
-------

"    %format% top
  

userstr <- paste(clus.table[,{
l <- .SD[currently %in% c("WAITING","RUNNG"),]
"For %(x0)s:
# of Clusters created in last 7 days    : %(x1)d
# of Currently running clusters         : %(x2)d
# Normalized Instance Hours             : %(x4)d
# age in days of oldest running cluster : %(x5)s 

    
    " %format% list( x0=.BY[[1]], x1=nrow(.SD), x2= sum(currently %in% c("WAITING","RUNNG")), x4=sum(hrs)
      ,x5=if(nrow(l)>0) sprintf("%s day(s)",max(Sys.Date()-crt)) else "none running")
},by=user]$V1,collapse="\n\n")



bd <- sprintf("%s%s",introStr,userstr)
library(sendmailR)
email(subj='Metrics AWS Cluster Report',body=bd,to="<metrics@mozilla.com>")

