#!/usr/bin/env python

from argparse import ArgumentParser
from flask import Flask, render_template, g, request, redirect, url_for, jsonify,session
from flask.ext.login import LoginManager, login_required, current_user
from flask.ext.browserid import BrowserID
from user import User, AnonymousUser
from urlparse import urljoin
from sqlalchemy import create_engine, MetaData
from sqlalchemy.sql import select, func
from tempfile import mkstemp
import json
import re
import os.path
from boto.emr.connection import EmrConnection
from boto.exception import EmrResponseError
from boto.emr.instance_group import InstanceGroup
from boto.emr import connect_to_region as emr_connect, BootstrapAction,JarStep
import boto
import time
import misc
import functools

# Create flask app
app = Flask(__name__)
app.debug=True
app.config.from_object('config')
EmrConnection.DefaultRegionName="us-east-1"
import datetime
start_time = datetime.datetime.now()


with open(app.config['FILE_FOR_SECKEY']) as f:
   l = f.readlines()
   app.config['SECRET_KEY'] = l[0].rstrip()
   app.config['ACCESS_ID']  = l[1].rstrip()
   
botoconn = EmrConnection(aws_access_key_id=app.config['ACCESS_ID'], aws_secret_access_key=app.config['SECRET_KEY'])
ec2boto = boto.connect_ec2(app.config['ACCESS_ID'], app.config['SECRET_KEY'])

__location__ = os.path.realpath(os.path.join(os.getcwd(), os.path.dirname(__file__)))

# Create login manager
login_manager = LoginManager()
login_manager.anonymous_user = AnonymousUser

# Initialize browser id login
browser_id = BrowserID()

import functools
pctfunction = functools.partial(misc.percentile,percent=app.config['SPOT_PRICE_PCT_RULE'])



class back(object):
    ## http://flask.pocoo.org/snippets/120/
    cfg = app.config.get
    cookie = cfg('REDIRECT_BACK_COOKIE', 'back')
    default_view = cfg('REDIRECT_BACK_DEFAULT', 'index')

    @staticmethod
    def anchor(func, cookie=cookie):
        @functools.wraps(func)
        def result(*args, **kwargs):
            session[cookie] = request.url
            return func(*args, **kwargs)
        return result

    @staticmethod
    def url(default=default_view, cookie=cookie):
        return session.get(cookie, url_for(default))

    @staticmethod
    def redirect(default=default_view, cookie=cookie):
        return redirect(back.url(default, cookie))
back = back()




@browser_id.user_loader
def get_user(response):
    """Create User from BrowserID response"""
    if response['status'] == 'okay':
        return User(response['email'])
    return User(None)

@login_manager.user_loader
def load_user(email):
    """Create user from already authenticated email"""
    return User(email)

@login_manager.unauthorized_handler
def unauthorized():
    return render_template('index.html')

@app.before_first_request
def initialize_jobs():
    pass

@app.teardown_appcontext
def close_db(error):
    """Closes the database again at the end of the request."""
    pass

task_node_max_price = { 'm3.xlarge':0.28, 'm3.2xlarge':0.56,'m1.large':0.175,'m1.medium':0.087,'c3.xlarge':0.210}
def summarizeSpot(prices,mtype=None):
   x =  pctfunction(prices)
   if x> task_node_max_price[mtype]:
      return(task_node_max_price[mtype])
   else:
      return(x)

import datetime
cached_price_history={}
def getSpotPriceHistoryFor(conn, mtype, numdays,detail=False):
   timenow = datetime.datetime.now()
   def recompPrice(numdays1):
      tn = timenow - datetime.timedelta(days=numdays1)
      tn = tn.strftime("%Y-%m-%dT%H:%M:%S.000Z")
      h= conn.get_spot_price_history(start_time=tn, product_description="Linux/UNIX (Amazon VPC)",instance_type=mtype)
      cached_price_history[ (mtype, numdays1)] = [l.price for l in h]
   cached=True
   print( cached_price_history.get( (mtype, numdays),"FOOOF:F"))
   if (timenow - start_time).seconds > 60  or cached_price_history.get( (mtype, numdays),None) == None:
      ## do a query and repopulate the cache
      cached = False
      recompPrice(numdays)
   print({'mtype':mtype, 'num':numdays,'cached':cached,'prices':cached_price_history[ (mtype, numdays) ]})
   return {'cached':cached,'prices':cached_price_history[ (mtype, numdays) ]}

def get_clusters_for_user(conn,username):
    def doesThisClusterCorrespondToUser(c):
        ## will fail if the user chooses to delete their tags ...
        tags = c.tags
        if len(tags) == 0:
            return False
        yes=False
        for l in tags:
            if l.key == "user" and l.value==username:
                yes=True
                break
        return yes
    def get_node_info_for_cluster(anid):
        instancegroups=conn.list_instance_groups(anid)
        core,task = 0,0
        if instancegroups is None:
            return 0,0
        for ig in instancegroups.instancegroups:
            if ig.instancegrouptype == 'CORE':
                core = core +int( ig.runninginstancecount)
            elif ig.instancegrouptype == 'TASK':
                task = task + int(ig.runninginstancecount)
        return core,task
    def getIP(cc):
        try:
            return(clusdec.masterpublicdnsname)
        except:
            return "..."
    def getReadyTime(cc):
        try:
           date_format='%m/%d/%Y %H:%M:%S %Z'
           redyTime = str(clusdec.status.timeline.readydatetime)
           try:
              import time,pytz, calendar
              redyTime = time.strptime(redyTime[:-5],"%Y-%m-%dT%H:%M:%S")
              return(datetime.datetime.fromtimestamp(calendar.timegm(redyTime), tz=pytz.timezone("US/Pacific")).strftime("%Y-%m-%d %H:%M") + " PDT")
           except:
              return(redyTime)
        except:
            return "..."
    try:
        list_of_clusters = conn.list_clusters(cluster_states=["TERMINATING","BOOTSTRAPPING","WAITING","RUNNING","STARTING"])
        toreturn = []
        if list_of_clusters is not None:
            cluster_list = list_of_clusters.clusters
            i = 0
            for acluster in cluster_list:
                clusdec = conn.describe_cluster(acluster.id)
                if doesThisClusterCorrespondToUser(clusdec):
                    i = i+1
                    en = { 'index':str(i), 'id' : clusdec.id, 'name' : clusdec.name,    'instancehrs': getattr(clusdec,'normalizedinstancehours',0),
                           'ip' : getIP(clusdec), 'state' : clusdec.status.state, 'ready' :getReadyTime(clusdec)}
                    en['corenodes'],en['tasknodes'] = get_node_info_for_cluster(clusdec.id)
                    toreturn.append(en)
        return False,toreturn
    except EmrResponseError,e:
        import traceback
        traceback.print_tb(e)
        return True, e

spotcache = {}
@app.route("/spotprices",methods=["GET"])
def spotprices():
   timenow=datetime.datetime.now()
   def recompPrice(ndays,mtype):
      if (timenow - start_time).seconds > 60 or spotcache.get( (mtype, ndays),None) == None:
         tn = timenow - datetime.timedelta(days=ndays)
         tn = tn.strftime("%Y-%m-%dT%H:%M:%S.000Z")
         h= ec2boto.get_spot_price_history(start_time=tn, product_description="Linux/UNIX (Amazon VPC)",instance_type=mtype)
         spotcache[ (mtype, numdays)] = [ { 'price':l.price, 'time':l.timestamp} for l in h]
         return {'cached': False, 'prices': spotcache[ (mtype,numdays) ]}
      else:
         return {'cached': True, 'prices' : spotcache[ (mtype,numdays) ]}
   formdata = request.args
   formdict = formdata.to_dict()
   print(formdict)
   nodetype = formdict.get("type",app.config['MASTER_INSTANCE_TYPE'])
   numdays  = int(formdict.get("numdays", 3))
   print(numdays)
   priceInfo = recompPrice(numdays, nodetype)
   priceInfo['node'] = nodetype
   priceInfo['numdays'] = numdays
   return jsonify(priceInfo)

@app.route("/modify_cluster", methods=["POST","GET"])
@login_required
def modify_cluster():
    def adjustTG(c,numgr):
      w1 = botoconn.list_instance_groups(c)
      if numgr>0:
         priceInfo= getSpotPriceHistoryFor(ec2boto, app.config['TASK_NODE_TYPE'], 1)
         sp =  str(round(summarizeSpot(priceInfo['prices'],app.config['TASK_NODE_TYPE']),3))
         igr = InstanceGroup(numgr, "TASK",app.config['TASK_NODE_TYPE'],"SPOT","user-spot",sp)
         botoconn.add_instance_groups(c,[igr])
      else:
         ## kill em all!
         taskig = []
         for ig in w1.instancegroups:
             if ig.instancegrouptype == "TASK":
                taskig.append(ig)
         n = [0] * len(taskig)
         botoconn.modify_instance_groups( [x.id for x in taskig], n)
    if not current_user.is_authorized():
        return login_manager.unauthorized()
    formdata = request.form
    ## operations include num of spots, clusid and whether to kill
    clusops = {}
    formdict = formdata.to_dict()
    for key,value in formdict.iteritems():
        if key.startswith("clus"):
            clusops[ value ] = {}
    for key in clusops:
        clusops[ key ]['kill'] = formdict.get(key+"-kill","off")
        ## -1 means no change ...
        clusops[ key ]['newspot'] = int(formdict.get(key+"-spot")) if formdict.get(key+"-spot") not in (None,'')  else -1
    # import pdb; pdb.set_trace()
    for key,value in clusops.iteritems():
        if value['kill'] == 'on':
            ## terminate job
            botoconn.terminate_jobflow(key)
        elif int(value['newspot']) >= 0:
            ## spots are either 0 or >0, in any case run a modification
            adjustTG(key,int(value['newspot']))
    return back.redirect()

def checkIfUserSubmittedKey():
    res = False
    content = None
    try:
        f = open(os.path.join(__location__, current_user.email+".datjson"));
        res=True
        import json
        content = json.load(f)['pubkey']
    except IOError:
        pass
    return( res,content)

user_clusters = {}
@app.route('/', methods=["GET"])
@back.anchor
def index():
    from datetime import datetime
    from pytz import timezone
    import pytz
    date_format='%m/%d/%Y %H:%M:%S %Z'
    priceInfo = getSpotPriceHistoryFor(ec2boto, app.config['TASK_NODE_TYPE'], 3)
    spotForM1Large = summarizeSpot(priceInfo['prices'],app.config['TASK_NODE_TYPE'])
    if current_user.is_authorized():
        ## we need to get a list of clusters and display them
        getnew=False
        if current_user.email  in user_clusters:
            err = user_clusters[current_user.email]['err']
            ls = user_clusters[current_user.email]['ls']
            last = user_clusters[current_user.email]['last']
            timecheck = user_clusters[current_user.email]['timecheck']
            if int(time.time()) - last > app.config['REFRESH_TIME'] or current_user.email=='sguha@mozilla.com':
                getnew=True
        else:
            getnew=True
        if getnew:
            timecheck=datetime.now(tz=timezone("US/Pacific")).strftime(date_format)
            err, ls = get_clusters_for_user(botoconn, current_user.email)
            user_clusters[current_user.email]={'last':int(time.time()), 'err':err, 'ls':ls,'timecheck':timecheck}
        if err:
            lsstr = str(ls)
        else:
            lsstr = ""
        userhaskey,content = checkIfUserSubmittedKey()
        return render_template('index.html', err=err, clusters=ls,message=lsstr
                               ,userhaskey=userhaskey, pubkey = content
                               ,timecheck="Last checked at "+timecheck,spot = "$"+str(spotForM1Large))
    else:
        return render_template('index.html')


def writeKeyIfNotAlready(akey):
    if akey == "":
        ## this can only be missing, if a key is already present
        return
    ## user provided a key
    import json
    try:
        f = open(os.path.join(__location__, current_user.email+".datjson"));
        content = json.load(f)
    except IOError:
        ## most likely first time,
        content = {}
    content['pubkey'] = akey
    with open(os.path.join(__location__, current_user.email+".datjson"), 'w') as outfile:
        json.dump(content, outfile,sort_keys = True, indent = 4,ensure_ascii=False)
    return
        
@app.route("/status", methods=["GET"])
def status():
    return "OK"

numclusters={}
@app.route("/new_cluster", methods=["POST"])
def newcluster():
    def is_instance_type_okay_fordisks():
        def isthisOkay(t):
            if t == 'm3.xlarge' or t=="m3.2xlarge" or t=="c3.2xlarge" or t=="c3.4xlarge":
                return True
            else:
                return False
        if isthisOkay(app.config['MASTER_INSTANCE_TYPE']) and isthisOkay(app.config['CORE_INSTANCE_TYPE']) and isthisOkay(app.config['TASK_NODE_TYPE']):
                return True
        else:
            return False
    formdata = request.form
    formdict = formdata.to_dict()
    pubkey = request.files['public-ssh-key'].read()
    writeKeyIfNotAlready(pubkey)
    numnodes = formdict['numnodes']
    desc = formdict['clusdesc']
    if desc=='':
        i= numclusters.get(current_user.email,0)
        desc = "Cluster #"+str(i)+" for "+current_user.email
    if numnodes == '':
        numnodes = app.config['DEFAULT_CORE_NODES']
    else:
        numnodes = int(numnodes)
    ## see https://anujjaiswal.wordpress.com/2015/02/10/aws-emr-high-performance-bootstrap-action/
    hadoop_config_options = ["-m","mapred.map.child.java.opts=-Xmx1024m",
                            "-m","mapred.reduce.child.java.opts=-Xmx1024m",
                            "-y",
                            "yarn.resourcemanager.scheduler.class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fair.FairScheduler"]
    
    hadoop_config_options=hadoop_config_options+["-y", "yarn.log-aggregation-enable=true", 
                                 "-y", "yarn.log-aggregation.retain-seconds=-1", 
                                 "-y", "yarn.log-aggregation.retain-check-interval-seconds=3000", 
                                 "-y", "yarn.nodemanager.remote-app-log-dir=s3://mozillametricsemrscripts/aggreglogs"]

    hadoop_config_options=hadoop_config_options+[ "-m", "mapreduce.map.output.compress=true", 
                                  # "-m", "mapreduce.map.output.compress.codec=org.apache.hadoop.io.compress.SnappyCodec", 
                                  "-m", "mapreduce.output.fileoutputformat.compress=true"
                                  # "-m", "mapreduce.output.fileoutputformat.compress.codec=org.apache.hadoop.io.compress.SnappyCodec"
    ]

    hadoop_config_options=hadoop_config_options+[ "-c", "fs.s3n.multipart.uploads.enabled=true",
                                  "-c", "fs.s3n.multipart.uploads.split.size=524288000"]
    if is_instance_type_okay_fordisks():
        hadoop_config_options=hadoop_config_options+[
           "-m", "mapreduce.map.memory.mb=4096",
           "-m", "mapreduce.map.java.opts=-Xmx4096m"
           # "-m", "mapreduce.map.java.opts=-XX:-UseGCOverheadLimit",
           # "-m", "mapred.local.dir=\"/mnt/var/lib/hadoop/mapred,/mnt1/var/lib/hadoop/mapred\"",
           # "-h", "dfs.data.dir=/mnt/var/lib/hadoop/dfs,/mnt1/var/lib/hadoop/dfs",
           # "-h", "dfs.name.dir=/mnt/var/lib/hadoop/dfs-name,/mnt1/var/lib/hadoop/dfs-name"
           # "-c", "hadoop.tmp.dir=/mnt/var/lib/hadoop/tmp,/mnt1/var/lib/hadoop/tmp", 
           # "-c", "fs.s3.buffer.dir='/mnt/var/lib/hadoop/s3,/mnt1/var/lib/hadoop/s3'", 
           # "-y", "yarn.nodemanager.local-dirs='/mnt/var/lib/hadoop/tmp/nm-local-dir,/mnt1/var/lib/hadoop/tmp/nm-local-dir'"
           ]
    setup_hadoop_boostrap = BootstrapAction('Configure Hadoop',
                                            's3://elasticmapreduce/bootstrap-actions/configure-hadoop',
                                            hadoop_config_options)
                                    
    setup_rhipekickstart_bootstrap = BootstrapAction('KickStart Rhipe',
                                                     's3://mozillametricsemrscripts/kickstartrhipe.sh',
                                                     ['--public-key', pubkey,
                                                      '--timeout', app.config['CLUSTER_LIFE_MIN']])

    finalStep  = JarStep(name         = 'Finalize HDFS'
                         ,jar         = 's3://elasticmapreduce/libs/script-runner/script-runner.jar'
                         ,step_args   = ['s3://mozillametricsemrscripts/final.step.sh'])

    jobid                                     = botoconn.run_jobflow(name = desc,
                                                                     ec2_keyname          = 'sguhaMozillaEast',
                                                                     log_uri              = "s3://mozillametricsemrscripts/logs",
                                                                     enable_debugging     = True,
                                                                     master_instance_type = app.config['MASTER_INSTANCE_TYPE'],
                                                                     slave_instance_type  = app.config['CORE_INSTANCE_TYPE'],
                                                                     num_instances        = numnodes+1,
                                                                     ami_version          = app.config['AMI_VERSION'],
                                                                     visible_to_all_users = True,
                                                                     keep_alive           = True,
                                                                     bootstrap_actions    = [setup_hadoop_boostrap, setup_rhipekickstart_bootstrap ],
                                                                     steps                = [finalStep]
                                                                 )
    botoconn.add_tags(jobid, {
        "user": current_user.email,
    })
    numclusters[current_user.email] = numclusters.get(current_user.email,0)+1
    return back.redirect()

@app.route('/graphs', methods=["GET"])
def graphs():
    if current_user.is_authenticated():
        print(current_user.is_authorized())
        print(current_user.email)
        print(dir(current_user))
    return render_template('index.html')
    

login_manager.init_app(app)
browser_id.init_app(app)

if __name__ == '__main__':
    parser = ArgumentParser(description='Tickle the Mozilla Monster')
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", default=8081, type=int)
    parser.add_argument("--db-url", default='sqlite:///mozmonster.db')
    args = parser.parse_args()

    app.config.update(dict(
        DB_URL = args.db_url,
        DEBUG = True
    ))

    app.run(host = args.host, port = args.port, debug=app.config['DEBUG'])
