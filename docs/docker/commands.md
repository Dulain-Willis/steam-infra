# Docker Commands

## System Storage

Show disk usage summary (images, containers, volumes, build cache):

    docker system df

Show verbose breakdown per image, container, and volume:

    docker system df -v

List all volumes:

    docker volume ls

List all images:

    docker image ls

Remove dangling images (untagged layers left behind after a rebuild — safe, does not touch named or running images):

    docker image prune -f

Remove all unused images, containers, networks, and volumes (destructive):

    docker system prune -a --volumes
