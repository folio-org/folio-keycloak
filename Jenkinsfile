import org.folio.eureka.EurekaImage
import org.jenkinsci.plugins.workflow.libs.Library

@Library('pipelines-shared-library@MD-number-fix') _
node('jenkins-agent-java17') {
    stage('Build Docker Image') {
        dir('folio-keycloak') {
            EurekaImage image = new EurekaImage(this)
            image.setModuleName('folio-keycloak')
            image.makeImage()
        }
    }
}