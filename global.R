# =========================================================================== #
# global.R  --  loaded once by Shiny (with the app directory as the working
# directory) before ui.R / server.R. Holds shared library loads and the
# demand + supply engine so both ui and server can rely on them.
# =========================================================================== #

library(shiny)
library(shinyjs)
library(shinythemes)
library(shinycssloaders)
library(DT)
library(rhandsontable)
library(ggplot2)
library(plotly)
library(dplyr)
library(tidyr)
library(lubridate)
library(stringr)
library(readxl)

# Use Cairo for bitmap rendering so plots work in a headless R process (the
# macOS default 'quartz' device needs a window server and fails when the app is
# run as a background/daemon process -> "invalid quartz() device size").
if (capabilities("cairo")) {
  options(bitmapType = "cairo", shiny.usecairo = TRUE)
}

# Shared engine: single source of truth for the app, the notebook, and the
# headless runner (R/run_simulation.R).
source("R/simulation.R", local = FALSE)
source("R/inventory.R", local = FALSE)
