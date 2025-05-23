# Copyright 2019 Observational Health Data Sciences and Informatics
#
# This file is part of DDLGeneratr
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#' Write DDL script
#'
#' Write the DDL to a SQL file. The SQL will be rendered (parameters replaced) and translated to the target SQL
#' dialect. By default the @cdmDatabaseSchema parameter is kept in the SQL file and needs to be replaced before
#' execution.
#'
#' @param targetDialect  The dialect of the target database. Support dialects are specified by SqlRender::listSupportedDialects
#' @param cdmVersion The version of the CDM you are creating, e.g. 5.3, 5.4
#' @param outputfolder The directory or folder where the SQL file should be saved.
#' @param cdmDatabaseSchema The schema of the CDM instance where the DDL will be run. For example, this would be "ohdsi.dbo" when testing on sql server.
#'                          Defaults to "@cdmDatabaseSchema"
#' @return Writes SQL file with the OMOP CDM DDL for the specified CDM version and target dialect in the output folder.
#'
#' @export
writeDdl <- function(targetDialect, cdmVersion, outputfolder, cdmDatabaseSchema = "@cdmDatabaseSchema") {

  # argument checks
  stopifnot(targetDialect %in% c("postgresql"))
  stopifnot(cdmVersion %in% c("0.1"))
  stopifnot(is.character(cdmDatabaseSchema))

  if(missing(outputfolder)) {
    outputfolder <- file.path("ddl", cdmVersion, gsub(" ", "_", targetDialect))
  }

  if(!dir.exists(outputfolder)) dir.create(outputfolder, showWarnings = FALSE, recursive = TRUE)

  sql <- createDdl(cdmVersion)
  sql <- SqlRender::render(sql = sql, cdmDatabaseSchema = cdmDatabaseSchema, targetDialect = targetDialect)
  sql <- SqlRender::translate(sql, targetDialect = targetDialect)

  filename <- paste("gaia", gsub(" ", "_", targetDialect), cdmVersion, "ddl.sql", sep = "_")
  SqlRender::writeSql(sql = sql, targetFile = file.path(outputfolder, filename))
  invisible(filename)
}

#' @describeIn writeDdl writePrimaryKeys Write the SQL code that creates the primary keys to a file.
#' @return Writes a SQL file with the primary keys for the OMOP CDM based on the specified target dialect and CDM version.
#' @export
#'
writePrimaryKeys <- function(targetDialect, cdmVersion, outputfolder, cdmDatabaseSchema = "@cdmDatabaseSchema") {

  # argument checks
  stopifnot(targetDialect %in% c("postgresql"))
  stopifnot(cdmVersion %in% c("0.1"))
  stopifnot(is.character(cdmDatabaseSchema))

  if(missing(outputfolder)) {
    outputfolder <- file.path("ddl", cdmVersion, gsub(" ", "_", targetDialect))
  }

  if(!dir.exists(outputfolder)) dir.create(outputfolder, showWarnings = FALSE, recursive = TRUE)

  sql <- createPrimaryKeys(cdmVersion)
  sql <- SqlRender::render(sql = sql, cdmDatabaseSchema = cdmDatabaseSchema, targetDialect = targetDialect)
  sql <- SqlRender::translate(sql, targetDialect = targetDialect)

  filename <- paste("gaia", gsub(" ", "_", targetDialect), cdmVersion, "primary", "keys.sql", sep = "_")
  SqlRender::writeSql(sql = sql, targetFile = file.path(outputfolder, filename))
  invisible(filename)
}

#' @describeIn writeDdl writeForeignKeys Write the SQL code that creates the foreign keys to a file.
#' @return Writes a SQL file with the foreign keys for the OMOP CDM based on the specified target dialect and CDM version.
#' @export
writeForeignKeys <- function(targetDialect, cdmVersion, outputfolder, cdmDatabaseSchema = "@cdmDatabaseSchema") {

  # argument checks
  stopifnot(targetDialect %in% c("postgresql"))
  stopifnot(cdmVersion %in% c("0.1"))
  stopifnot(is.character(cdmDatabaseSchema))

  if(missing(outputfolder)) {
    outputfolder <- file.path("ddl", cdmVersion, gsub(" ", "_", targetDialect))
  }

  if(!dir.exists(outputfolder)) dir.create(outputfolder, showWarnings = FALSE, recursive = TRUE)

  sql <- createForeignKeys(cdmVersion)
  sql <- SqlRender::render(sql = sql, cdmDatabaseSchema = cdmDatabaseSchema, targetDialect = targetDialect)
  sql <- SqlRender::translate(sql, targetDialect = targetDialect)

  filename <- paste("gaia", gsub(" ", "_", targetDialect), cdmVersion, "constraints.sql", sep = "_")
  SqlRender::writeSql(sql = sql, targetFile = file.path(outputfolder, filename))
  invisible(filename)
}

#' @describeIn writeDdl writeIndex Write the rendered and translated sql that creates recommended indexes to a file.
#' @return Writes a SQL file with the indices for the OMOP CDM based on the specified target dialect and CDM version.
#' @export
writeIndex <- function(targetDialect, cdmVersion, outputfolder, cdmDatabaseSchema  = "@cdmDatabaseSchema") {

  # argument checks
  stopifnot(targetDialect %in% c("postgresql"))
  stopifnot(cdmVersion %in% c("0.1"))
  stopifnot(is.character(cdmDatabaseSchema))

  if(missing(outputfolder)) {
    outputfolder <- file.path("ddl", cdmVersion, gsub(" ", "_", targetDialect))
  }

  if(!dir.exists(outputfolder)) dir.create(outputfolder, showWarnings = FALSE, recursive = TRUE)

  sqlFilename <- paste0("OMOP_CDM_indices_v", cdmVersion, ".sql")
  sql <- readr::read_file(system.file(file.path("sql", "sql_server", sqlFilename), package = "CommonDataModel"))
  sql <- SqlRender::render(sql, targetDialect = targetDialect, cdmDatabaseSchema = cdmDatabaseSchema)
  sql <- SqlRender::translate(sql, targetDialect = targetDialect)

  filename <- paste("gaia", gsub(" ", "_", targetDialect), cdmVersion, "indices.sql", sep = "_")
  SqlRender::writeSql(sql = sql, targetFile = file.path(outputfolder, filename))
  invisible(filename)
}
