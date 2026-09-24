# Purpose

This codebase is to handle all the mutual parts of deploying 20 web applications to a VPS. This includes nginx configurations and other platforms services.
This also includes ALL provisioning required to configure the host from scratch.

# What's Included

* Platform Services
  * Nginx
  * Certbot
  * Docker
  * PHP-FPM for PHP apps
  * Redis
* Log Rotation
* APM - Processor, RAM, Drive Space Management
* Bootstrap - Provisioning script for all required dependencies

# External Platform Services

* MySQL - The default database.
* Digital Ocean Spaces - Should be used to keep disk space low. Every app should have this configured.

# Deployment

Applications either deploy with GitHub Actions and Docker, or they have manual deployment mechanisms. It's preferred to deploy through GitHub Actions.

Applications are expected to have their own deployments saved in their repo, this helps CI work. This means Nginx confs should exist in each app.

Secrets should come from GitHub Actions.

To keep Redis accessible, it should be in one container running on the machine.

# Simple Sites

Basic sites not needing their own dedicated git repo can have their sites here.

# Changes

Any time there is any change to the server, it should be documented here. Whenever there is a change here, it should run on the server.