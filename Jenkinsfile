pipeline {
    agent any

    environment {
        APP_DIR         = '/opt/crud-api'
        VENV_DIR        = '/opt/crud-api/venv'
        APP_PORT        = '8000'
        // Health check parameters — defined here, not magic numbers in shell
        HC_RETRIES      = '5'
        HC_WAIT_SECS    = '6'   // total wait: 5 * 6 = 30 seconds before declaring failure
        HC_TIMEOUT_SECS = '5'   // curl per-request timeout
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build') {
            steps {
                sh '''
                    set -e
                    python3 -m venv ${VENV_DIR}
                    ${VENV_DIR}/bin/pip install --upgrade pip
                    ${VENV_DIR}/bin/pip install -r requirements.txt
                '''
            }
        }

        stage('Test') {
            steps {
                sh '''
                    set -e
                    ${VENV_DIR}/bin/pytest tests/ -v --tb=short
                '''
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([string(credentialsId: 'DATABASE_URL', variable: 'DATABASE_URL')]) {
                    sh '''
                        set -e

                        # Snapshot current deployed commit for rollback
                        if [ -L ${APP_DIR}/current ]; then
                            PREV=$(readlink ${APP_DIR}/current)
                            echo "${PREV}" > /tmp/crud_api_prev_release
                        fi

                        # Create a timestamped release directory
                        RELEASE_DIR="${APP_DIR}/releases/$(date +%Y%m%d%H%M%S)"
                        mkdir -p "${RELEASE_DIR}"
                        cp -r . "${RELEASE_DIR}/"

                        # Write .env from Jenkins credentials — never touches the repo
                        echo "DATABASE_URL=${DATABASE_URL}" > "${RELEASE_DIR}/.env"
                        echo "APP_PORT=${APP_PORT}" >> "${RELEASE_DIR}/.env"
                        echo "APP_ENV=production" >> "${RELEASE_DIR}/.env"

                        # Run DB migrations before switching traffic
                        ${VENV_DIR}/bin/alembic -c "${RELEASE_DIR}/alembic.ini" upgrade head

                        # Symlink current release
                        ln -sfn "${RELEASE_DIR}" ${APP_DIR}/current

                        # Restart app via systemd (service file pre-configured on server)
                        sudo systemctl restart crud-api
                    '''
                }
            }
        }

        stage('Health Check') {
            steps {
                script {
                    def healthy = false
                    def retries = env.HC_RETRIES.toInteger()
                    def waitSecs = env.HC_WAIT_SECS.toInteger()
                    def timeoutSecs = env.HC_TIMEOUT_SECS.toInteger()

                    for (int i = 1; i <= retries; i++) {
                        echo "Health check attempt ${i}/${retries}..."
                        def result = sh(
                            script: """
                                STATUS=\$(curl -s -o /tmp/hc_body.json -w '%{http_code}' \
                                    --max-time ${timeoutSecs} \
                                    http://localhost:${env.APP_PORT}/health)
                                DB_STATUS=\$(python3 -c "import json; d=json.load(open('/tmp/hc_body.json')); print(d.get('database','unknown'))")
                                echo "HTTP \${STATUS} | DB: \${DB_STATUS}"
                                [ "\${STATUS}" = "200" ] && [ "\${DB_STATUS}" = "ok" ]
                            """,
                            returnStatus: true
                        )
                        if (result == 0) {
                            echo "Health check passed on attempt ${i}."
                            healthy = true
                            break
                        }
                        if (i < retries) {
                            echo "Not healthy yet, waiting ${waitSecs}s..."
                            sleep(waitSecs)
                        }
                    }

                    if (!healthy) {
                        error("Health check failed after ${retries} attempts — triggering rollback.")
                    }
                }
            }
        }
    }

    post {
        failure {
            script {
                echo "Pipeline failed — attempting rollback..."
                sh '''
                    set -e
                    if [ -f /tmp/crud_api_prev_release ]; then
                        PREV=$(cat /tmp/crud_api_prev_release)
                        if [ -d "${PREV}" ]; then
                            echo "Rolling back to ${PREV}"
                            ln -sfn "${PREV}" /opt/crud-api/current
                            sudo systemctl restart crud-api
                            echo "Rollback complete."
                        else
                            echo "Previous release directory not found — manual intervention required."
                        fi
                    else
                        echo "No previous release recorded — skipping rollback."
                    fi
                '''
            }
        }
        success {
            echo "Deployment successful. App is healthy at port ${APP_PORT}."
        }
    }
}
