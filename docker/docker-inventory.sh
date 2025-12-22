#!/bin/bash

# We do some inventory
# https://docs.docker.com/engine/reference/commandline/inspect/

# Get ContainerID
echo "*----* CONTAINER ID *----*"

CONTAINERID= docker ps -a | tail -n +2 | awk '{print $1}'

echo $CONTAINERID

# Get Container Name 
echo "*----* CONTAINER NAME *----*"

CONTAINER_NAME= docker ps -a | tail -n +2 | awk '{print $2}'

echo $CONTAINER_NAME

# Get Command
echo "*----* SHELL & CREATED *-----*"

CONTAINER_SHELL= docker ps -a | tail -n +2 | awk '{print $3, $4, $5, $6, $7, $8, $9}' # need to get rid of 5 cutting some stuff in 

echo $CONTAINER_SHELL

# Status(es)
echo "---- STATUS ----"

CONTAINER_STATUS= docker ps -a | tail -n +1 | awk '{print $9, $10, $11}'

echo $CONTAINER_STATUS

# CONTAINER_STATUS= docker ps -a | tail -n +1 | awk '{print $6, $7, $8, $9}'

# echo $CONTAINER_STATUS
# Ports 
echo "---- PORTS ----"

# Exposed Ports 
echo "---- EXPOSED PORTS ----"

# Inspect Docker Container(s) 
# Grabs LogPath and Most Recent container logs

