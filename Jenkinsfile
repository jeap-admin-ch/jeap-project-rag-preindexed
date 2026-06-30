@Library('jeap-pipelinelibrary@master') _

// Index the jEAP codebase once per week (Monday morning), and additionally
// whenever the jeap-spring-boot-parent has been built successfully.
properties([
    pipelineTriggers([
        cron('H 3 * * 1'),
        upstream(
            upstreamProjects: 'BIT/jEAP/jeap.jeap-spring-boot-parent/master',
            threshold: hudson.model.Result.SUCCESS
        )
    ])
])

def baseTag = '0.1.0-al2023'
def timestamp = new Date().format('yyyyMMddHHmmss', TimeZone.getTimeZone('UTC'))
def imageTag = "${baseTag}-${timestamp}"

dockerPipelineTemplate {
    masterBranchName = 'master'
    imageName = 'bit/jeap-project-rag-preindexed'
    dockerBuild = [
      '.': "${imageTag}, latest"
    ]
}
