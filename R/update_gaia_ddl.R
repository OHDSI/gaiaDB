library(SqlRender)
source("R/createDdl.R")
source("R/writeDdl.R")
gaiaVersion <- "0.1"
# for (dialect in c("postgresql")) {
for (dialect in c("postgresql")) {
    writeDdl(dialect, gaiaVersion)
    writePrimaryKeys(dialect, gaiaVersion)
    writeForeignKeys(dialect, gaiaVersion)
}

# I want to use SqlRender to generate a file init2.sql that takes init_template.sql and replaces the gaia_ddl.sql placeholder with the actual DDL

# read sql file in as text

ddl_sql <- render(sql = readSql(paste0("ddl/", gaiaVersion,"/postgresql/gaia_postgresql_", gaiaVersion,"_ddl.sql")), cdmDatabaseSchema="backbone")

SqlRender::renderSqlFile("ddl/init_template.sql", "init.sql", gaia_ddl = ddl_sql)

