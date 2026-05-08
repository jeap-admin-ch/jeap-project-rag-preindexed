@Library('jeap-pipelinelibrary@master') _

def baseTag = '0.1.0-al2023'
def timestamp = new Date().format('yyyyMMddHHmmss', TimeZone.getTimeZone('UTC'))
def imageTag = "${baseTag}-${timestamp}"

dockerPipelineTemplate {
    masterBranchName = 'master'
    imageName = 'bit/jeap-project-rag-preindexed'
    dockerBuild = [
      '.': imageTag
    ]
}
