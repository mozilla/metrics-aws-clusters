# metrics-aws-clusters
Dashboard to Create AWS Clusters for the Mertrics Team

This application uses Flask. You need a file called scr.dat (see config.py) the first line of which is your Amazon AWS_SECRET_ACCESS_KEY
and the second line is the AWS_ACCESS_ID.

You'll also need to edit the line of valid email ids in the file user.py so that you'll be allowed to login.

But the cluster wont start because some files are on my private S3 folder. The files are 

- s3://mozillametricsemrscripts/kickstartrhipe.sh
- s3://mozillametricsemrscripts/final.step.sh

Both of these files are in this github repo. But they depend on files created by  https://github.com/mozilla/metrics-aws-clusters/blob/master/bootscriptsAndR/sequence.of.commands.to.create.mozilla.metrics.emr.kickstart.files.sh
the output of which is stored in S3. I will update this README with a link to the files in the S3 bucket.

The cluster will start with some R packages and RHIPE 0.75. See https://github.com/mozilla/metrics-aws-clusters/blob/master/bootscriptsAndR/sequence.of.commands.to.create.mozilla.metrics.emr.kickstart.files.sh#L28
for what  R packages are installed.


