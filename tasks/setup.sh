#!/bin/bash

warn() {
    echo "$@" >&2
}

die() {
    warn "$@"
    exit 1
}

set -e

####
#### Disable email signups (to make the banner go away)
####
gitlab-rails r 'ApplicationSetting.last.update(signup_enabled: false) if ApplicationSetting.last[:signup_enabled]'

####
#### Add sample labels
####

# Get the top-level puppet group id
group_id=$( gitlab -o json group list | jq '.[] | select(.name == "puppet") | .id' )

# Get the list of group labels
group_labels=$( gitlab -o json group-label list --group-id "$group_id" )

# Add labels
declare -A label_descriptions=(
    [Bug]='Issue describes a bug'
    [Feature\ Request]='Issue describes a feature request'
    [Tech\ Debt]='Issue describes known tech debt'
    [In\ Progress]='Issue is actively being worked'
    [On\ Hold]='Issue is blocked by other work'
    [Pending\ Review]='Merge request created'
)

declare -A label_colors=(
    [Bug]=red
    [Feature\ Request]=blue
    [Tech\ Debt]=gray
    [In\ Progress]=green
    [On\ Hold]=orange
    [Pending\ Review]=purple
)

for label in "${!label_descriptions[@]}" ; do
    if [ -z "$( echo "$group_labels" | jq ".[] | select(.name == \"$label\")" )" ] ; then
        gitlab -o json group-label create \
            --group-id "$group_id" \
            --name "$label" \
            --color "${label_colors[$label]}" \
            --description "${label_descriptions[$label]}"
    fi
done

# Get the updated list of group labels
group_labels=$( gitlab -o json group-label list --group-id "$group_id" )

####
#### Add sample issues
####

# Get the control repo project id
control_repo_id=$( gitlab -o json project list | jq '.[] | select(.path_with_namespace == "puppet/control") | .id' )

# Get a list of issues in the control repo
control_repo_issues=$( gitlab -o json project-issue list --project-id "$control_repo_id" )

# Add issues
declare -A issue_descriptions=(
    ['Add zram']='Enable the [`zram`](https://forge.puppet.com/silug/zram) Puppet module on all nodes.'
    ['Enable eyaml']=$'All secrets should be encrypted.  At a minimum, this would require:\n* [ ] Enable eyaml on the Puppet node(s)\n* [ ] Update the import_control_repo task to encrypt secrets'
    ['Initial CI jobs fail']=$'Investigate initial CI job failures.\n\nSee [job #1](../../jobs/1) for an example.'
    ['GitLab demo']=$'Demonstrate:\n* [ ] repos/commits/branches/tags\n* [ ] wikis\n* [ ] issues/epics/milestones/boards\n* [ ] merge requests\n* [ ] CI pipelines/jobs\n\nDiscuss:\n* [ ] Container/package registry\n* [ ] SAST/DAST\n* [ ] k8s integration\n* [ ] Mattermost\n* [ ] CE vs EE\n* [ ] gitlab.com'
)

declare -A issue_labels=(
    ['Add zram']='Feature Request'
    ['Enable eyaml']='Tech Debt'
    ['Initial CI jobs fail']='Bug'
)

for issue in "${!issue_descriptions[@]}" ; do
    if [ -z "$( echo "$control_repo_issues" | jq ".[] | select(.title == \"$issue\")" )" ] ; then
        out=$( curl -s --request POST \
            --header "Private-Token: $( cat ~/.root_token )" \
            "http://localhost/api/v4/projects/${control_repo_id}/issues" \
            --form "title=${issue}" \
            --form "description=${issue_descriptions["$issue"]}" \
            --form "labels=${issue_labels["$issue"]}" )
        [ "$( echo "$out" | jq -r .title )" = "$issue" ] || die "Failed to add issue '$issue'"
    fi
done

####
#### Configure issue boards
####

# NOTE: The "Development" board is the only board supported in GitLab CE, so
#       I'm not checking that it exists before using it, but we do need to hit
#       the page first so that it is auto-created.
curl -s -H "Private-Token: $( cat ~/.root_token )" \
    http://localhost/groups/puppet/-/boards > /dev/null

# Get the list of boards
group_boards=$( gitlab -o json group-board list --group-id "$group_id" )

development_board=$( echo "$group_boards" | jq '.[] | select(.name == "Development")' )
development_board_id=$( echo "$development_board" | jq -r .id )

board_labels=(
    'In Progress'
    'Pending Review'
)

for label in "${board_labels[@]}" ; do
    if [ -z "$( echo "$development_board" | jq ".lists[].label | select(.name == \"$label\")" )" ] ; then
        label_id=$( echo "$group_labels" | jq -r ".[] | select(.name == \"$label\") | .id" )
        gitlab group-board-list create \
            --group-id "$group_id" \
            --board-id "$development_board_id" \
            --label-id "$label_id"
    fi
done

####
#### Add basic wikis
####

# We *can* do this via the API, but it's simpler to do it with git.
export GIT_AUTHOR_NAME='Import Bot'
export GIT_COMMITTER_NAME='Import Bot'
export GIT_AUTHOR_EMAIL=import-bot@$( hostname -f )
export GIT_COMMITTER_EMAIL=import-bot@$( hostname -f )

pushd /tmp

[ -d control.wiki ] || git clone git@localhost:puppet/control.wiki.git
pushd control.wiki

if [ ! -f home.md ] ; then
    cat > home.md <<END_CONTROL_HOME
This project is a clone of https://github.com/silug/gitlab-puppet.
END_CONTROL_HOME
    git add home.md
    git commit -m 'Create home'
    git push -u origin $( git branch --show-current )
fi
popd

[ -d puppet-deployment.wiki ] || git clone git@localhost:puppet/puppet-deployment.wiki.git
pushd puppet-deployment.wiki

if [ ! -f home.md ] ; then
    cat > home.md <<END_PUPPET_DEPLOYMENT_HOME
This project is a clone of https://github.com/silug/puppet-deployment.
END_PUPPET_DEPLOYMENT_HOME
    git add home.md
    git commit -m 'Create home'
    git push -u origin $( git branch --show-current )
fi
popd

popd

####
#### Import this repo
####
out=$( gitlab -o json project list | jq '.[] | select(.path_with_namespace == "gitlab_demo")' )
if [ -z "$out" ] ; then
    out=$( gitlab -o json project create --name gitlab_demo --visibility public --import-url https://github.com/silug/gitlab_demo.git )
    if [ "$?" -ne 0 ] ; then
        die "Failed to create gitlab_demo project"
    fi
fi
