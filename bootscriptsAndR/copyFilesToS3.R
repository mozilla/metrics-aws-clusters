source("~/prefix.R")
copyHDFSDirToS3 <- function(src, dest){
    files <- rhls(src)$file
    ## dest <- sprintf("%s/%s", dest,tail(strsplit(src,"/",fixed=TRUE)[[1]],1))
    local({
        x <- sprintf("aws s3 rm --recursive s3://%s/",dest)
        cat(x)
        system(x,intern=TRUE)
    })
    system.time(lapply(seq_along(files),function(i){
        localCopy <-  sprintf("%s/", tempdir())
        rhget(files[i], localCopy)
        localCopy <- sprintf("%s/%s", tempdir(),tail(strsplit(files[i],"/", fixed=TRUE)[[1]],1))
        cat(sprintf("Copying file %s (%s of %s) to s3://%s/ ... ", localCopy,i, length(files),dest))
        region <- 'us-east-1' #'US'
        ssize = as.numeric(file.info(localCopy)['size'])
        res <- system(cmd1 <- sprintf("aws s3 cp --expected-size %s --no-guess-mime-type  %s  s3://%s/part%s",ssize,localCopy,dest,i), intern=TRUE)
        unlink(localCopy)
        if(length(res)==0 || !is.null(attr(res, "status"))) {
            stop(sprintf("Error Copying %s",localCopy))
        }
        cat(sprintf(" copy success\n"))
        if(i %% 3 == 0) {cat(sprintf("Sleeping ...\n"));Sys.sleep(2)}
        res
    }))
}

copyHDFSDirToS3(src="/user/sguha/fhr/samples/output/1pct/p*", dest="mozillametricsemrscripts/fhr/samples/1pct/1")
copyHDFSDirToS3(src="/user/sguha/fhr/samples/output/5pct/p*", dest="mozillametricsemrscripts/fhr/samples/5pct/1")

