# gaiaDB 

### WARNING: this package is under-development and has only been tested using mock data

# Introduction 
TODO 

# Get Started 
The quickest way to start using gaiaDB is by building or downloading the docker image and running a container. Alternatively, you can execute the [init.sql](https://github.com/OHDSI/gaiaDB/blob/main/init.sql) script against your own PostgreSQL database.

## Dockerized gaiaDB

You can build and run gaiaDB as a docker container with the following commands:

```bash
git clone https://github.com/OHDSI/gaiaDB.git

cd gaiaDB

docker build -t gaia-db .

docker run -itd --rm -e POSTGRES_PASSWORD=SuperSecret -e POSTGRES_USER=postgres -p 5432:5432 --name gaia-db gaia-db
```

Once deployed and (automatically) initialized, the containerized Postgres database includes:
- GIS Catalog (`backbone` schema)
- Constrained GIS vocabulary tables (`vocabulary` schema)
- postgis tools (native to image, `tiger` schema)

# Support 
Please use the <a href="https://github.com/OHDSI/gaiaDB/issues">GitHub issue tracker</a> for data issues and requests

# Developer Guidelines

- Please create a new issue for changes 
- Please create a new branch with code changes and create a Pull Request when ready for merge
- Pull Requests must be reviewed before merging to main
