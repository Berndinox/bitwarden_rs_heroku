#!/bin/bash 
set -euo pipefail

SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ENABLE_DUO=0
CREATE_APP_NAME=" "
GIT_HASH="master"
BITWARDEN_RS_FOLDER="bitwarden_rs"
STRATEGY_TYPE="deploy"
HEROKU_VERIFIED=0
OFFSITE_HEROKU_DB=" "
SMTP_HOST=" "
SMTP_FROM_MAIL=" "
SMTP_FROM_NAME=" "
SMTP_USER=" "
SMTP_PASSWORD=" "

# Clean out any existing contents
rm -rf ./${BITWARDEN_RS_FOLDER}

function git_clone {
    GIT_HASH=$1
    echo "Clone current bitwarden_rs with depth 1"
    git clone --depth 1 https://github.com/dani-garcia/bitwarden_rs.git
    cd ./${BITWARDEN_RS_FOLDER}
    git checkout "${GIT_HASH}"
    cd ..
}

function sed_files {
    sed -i "$1" "$2"
}

function heroku_bootstrap {

    CREATE_APP_NAME=$1

    echo "Logging into Heroku Container Registry to push the image (this will add an entry in your Docker config)"
    heroku container:login

    echo "We must create a Heroku application to deploy to first."
    APP_NAME=$(heroku create "${CREATE_APP_NAME}" --region eu --json | jq --raw-output '.name')

    if [ "${HEROKU_VERIFIED}" -eq "1" ]
    then
        echo "We will use JawsDB Maria edition, which is free and sufficient for a small instance"
        heroku addons:create jawsdb -a "$APP_NAME"

        echo "Now we use the JAWS DB config as the database URL for Bitwarden"
        echo "Supressing output due to sensitive nature."
        heroku config:set DATABASE_URL="$(heroku config:get JAWSDB_URL -a "${APP_NAME}")" -a "${APP_NAME}" > /dev/null
    else
        heroku config:set DATABASE_URL="${OFFSITE_HEROKU_DB}" -a "${APP_NAME}" > /dev/null
    fi
    
    echo "Additionally set an Admin Token too in the event additional options are needed."
    echo "Supressing output due to sensitive nature."
    heroku config:set ADMIN_TOKEN="$(openssl rand -base64 48)" -a "${APP_NAME}" > /dev/null
    
    echo "Costum Env Inject"
    heroku config:set SMTP_HOST="$SMTP_HOST" -a "${APP_NAME}" > /dev/null
    heroku config:set SMTP_FROM="$SMTP_FROM_MAIL" -a "${APP_NAME}" > /dev/null
    heroku config:set SMTP_FROM_NAME="$SMTP_FROM_NAME" -a "${APP_NAME}" > /dev/null
    heroku config:set SMTP_USERNAME="$SMTP_USER" -a "${APP_NAME}" > /dev/null
    heroku config:set SMTP_PASSWORD="$SMTP_PASSWORD" -a "${APP_NAME}" > /dev/null
    
    echo "And set DB connections to seven in order not to saturate the free DB"
    heroku config:set DATABASE_MAX_CONNS=7 -a "${APP_NAME}"
}

function build_image {
    git_clone "${GIT_HASH}"

    cd "${SCRIPTPATH}"

    echo "Heroku uses random ports for assignment with httpd services. We are modifying the ROCKET_PORT for startup."
    sed_files '2 a export ROCKET_PORT=$PORT\n' ./${BITWARDEN_RS_FOLDER}/docker/start.sh

    if [ "${ENABLE_DUO}" -eq "1" ]
    then
        # Thank you bryanjhv!
        heroku config:set _ENABLE_DUO=true -a "${APP_NAME}"
    fi

    echo "Logging into Heroku Container Registry to push the image (this will add an entry in your Docker config)"
    heroku container:login

    echo "Now we will build the amd64 image to deploy to Heroku with the specified port changes"
    mv ./${BITWARDEN_RS_FOLDER}/docker/amd64/Dockerfile ./${BITWARDEN_RS_FOLDER}/Dockerfile
    cd ./${BITWARDEN_RS_FOLDER}
    heroku container:push web -a "${APP_NAME}"

    echo "Now we can release the app which will publish it"
    heroku container:release web -a "${APP_NAME}"
}

function login_heroku {
echo "Modify netrc file to include Heroku details"
cat >~/.netrc <<EOF
machine api.heroku.com
    login ${HEROKU_EMAIL}
    password ${HEROKU_API_KEY}
machine git.heroku.com
    login ${HEROKU_EMAIL}
    password ${HEROKU_API_KEY}
EOF
}

function help {
    printf "Welcome to help!\Use option -a for app name,\n-d <0/1> to enable duo,\n -g to set a git hash to clone bitwarden_rs from,\n and -t to specify if deployment or update!"
}

while getopts d:a:g:t:v:u:s:w:x:y:z flag
do
    case "${flag}" in
        d) ENABLE_DUO=${OPTARG};;
        a) CREATE_APP_NAME=${OPTARG};;
        g) GIT_HASH=${OPTARG};;
        t) STRATEGY_TYPE=${OPTARG};;
        v) HEROKU_VERIFIED=${OPTARG};;
        u) OFFSITE_HEROKU_DB=${OPTARG};;
        s) SMTP_HOST=${OPTARG};;
        w) SMTP_FROM_MAIL=${OPTARG};;
        x) SMTP_FROM_NAME=${OPTARG};;
        y) SMTP_USER=${OPTARG};;
        z) SMTP_PASSWORD=${OPTARG};;
        *) HELP;;
    esac
done
echo "Enable Duo: $ENABLE_DUO";
echo "Create App_Name: $CREATE_APP_NAME";
echo "Git Hash: $GIT_HASH";
echo "Heroku Verified: $HEROKU_VERIFIED";
echo "SMTP User: $SMTP_USER";

if [[ ${STRATEGY_TYPE} = "deploy" ]]
then
    echo "Run Heroku bootstrapping for app and Dyno creations."
    login_heroku
    heroku_bootstrap "${CREATE_APP_NAME}"
    APP_NAME=${CREATE_APP_NAME}
    build_image
    echo "Congrats! Your new Bitwarden instance is ready to use! Head to Heroku, find the app, and use Open App to register!"
elif [[ ${STRATEGY_TYPE} = "update" ]]
then
    APP_NAME=${CREATE_APP_NAME}
    login_heroku
    build_image
else
    echo "Unexpected workflow, failing build"
    exit 1
fi
