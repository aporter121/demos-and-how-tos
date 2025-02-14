library(tidyverse)
library(readxl)
library(rvest)
library(progress)
library(lubridate)

get_kh03_filelist <- function() {
  url <- paste(
    "https://www.england.nhs.uk",
    "statistics",
    "statistical-work-areas",
    "bed-availability-and-occupancy",
    "bed-data-overnight",
    sep = "/"
  )
  
  read_html(url) |>
    html_nodes("a") |>
    keep(~html_text(.x) |> str_detect("NHS organisations in England, Quarter.*XLS")) |>
    map(\(.x) {
      url <- html_attr(.x, "href")
      quarter <- html_text(.x) |>
        str_replace("^.*Quarter (.), (.{7}).*$", "\\2 Q\\1")
      
      list(url = url, quarter = quarter)
    }) |>
    rev()
}

process_kh03_file <- function(x) {
  url <- x[[1]]$url
  quarter <- x[[1]]$quarter
  
  if (quarter >= "2013-14 Q4") {
    file_extension <- ".xlsx"
    skip_rows <- 14
  } else {
    file_extension <- ".xls"
    skip_rows <- if (quarter >= "2010-11 Q3") 13 else 3
  }
  
  filename <- withr::local_tempfile(fileext = file_extension)
  download.file(url, filename, quiet = TRUE, mode = "wb")
  
  overall <- read_excel(filename, "NHS Trust by Sector", skip = 17, col_names = c(
    "year", "period_end", "skip_1", "org_code", "org_name", "skip_2",
    "available_general_and_acute", "available_learning_disabilities", "available_maternity", "available_mental_illness",
    "skip_3", "skip_4",
    "occupied_general_and_acute", "occupied_learning_disabilities", "occupied_maternity", "occupied_mental_illness",
    "skip_5", "skip_6", "skip_7", "skip_8", "skip_9", "skip_10"
  )) |>
    select(-matches("skip_\\d+")) |>
    pivot_longer(-(year:org_name)) |>
    separate(name, c("type", "specialty_group"), extra = "merge") |>
    drop_na(value) |>
    pivot_wider(names_from = type, values_from = value)
  
  by_specialty <- read_excel(filename, "Occupied by Specialty", skip = skip_rows) |>
    select(-1, -2, -3, -5) |>
    rename(org_code = 1) |>
    drop_na(org_code) |>
    pivot_longer(-org_code, names_to = "specialty", values_to = "occupied") |>
    separate(specialty, c("specialty_code", "specialty_name"), extra = "merge")
  
  specialty_groups <- list(
    "maternity" = c("501"),
    "learning_disabilities" = c("700"),
    "mental_illness" = c("710", "711", "712", "713", "715")
  ) |>
    enframe("specialty_group", "specialty_code") |>
    unnest(specialty_code) |>
    right_join(distinct(by_specialty, specialty_code), by = "specialty_code") |>
    mutate(across(specialty_group, replace_na, "general_and_acute")) |>
    arrange(specialty_code)
  
  overall |>
    rename(available_total = available, occupied_total = occupied) |>
    filter(available_total > 0 | occupied_total > 0) |>
    inner_join(specialty_groups, by = "specialty_group") |>
    inner_join(by_specialty, by = c("org_code", "specialty_code")) |>
    filter(occupied > 0) |>
    group_nest(across(year:occupied_total), .key = "by_specialty") |>
    mutate(
      period_start = as.Date(paste("1", period_end, str_sub(year, 1, 4)), "%d %B %Y") %m-% months(2),
      period_end = period_start %m+% months(3) %m-% days(1),
      quarter = quarter,
      year = NULL
    ) |>
    relocate(quarter, period_start, .before = period_end)
}
