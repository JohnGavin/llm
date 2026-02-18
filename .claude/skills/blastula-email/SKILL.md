# Email Automation with blastula

This skill covers sending automated, formatted emails from R scripts and GitHub Actions using the `blastula` package. It focuses on secure credential management and integrating rich content (plots, tables).

## Core Concepts

-   **Composition**: Creating email bodies using Markdown or R Markdown.
-   **Credentials**: Using `create_smtp_creds_key()` or environment variables for secure authentication.
-   **Sending**: Dispatching emails via SMTP servers (Gmail, Outlook, etc.).

## 1. Secure Credential Management

**NEVER hardcode passwords.** Use environment variables or system keychains.

### GitHub Actions (Secrets)
1.  Add secrets to repo: `GMAIL_USERNAME`, `GMAIL_APP_PASSWORD`.
2.  Pass to workflow:
    ```yaml
    env:
      GMAIL_USERNAME: ${{ secrets.GMAIL_USERNAME }}
      GMAIL_APP_PASSWORD: ${{ secrets.GMAIL_APP_PASSWORD }}
    ```

### R Script Usage
```r
library(blastula)

# Create credentials object from env vars
creds <- creds_envvar(
  user = "GMAIL_USERNAME",
  pass_envvar = "GMAIL_APP_PASSWORD",
  provider = "gmail"
)
```

## 2. Composing Emails

### Basic Markdown
```r
email <- compose_email(
  body = md(c(
    "## Hello!",
    "Here is the *daily report*."
  )),
  footer = md("Sent via blastula")
)
```

### With Plots & Tables
```r
library(ggplot2)
library(gt)

# Create a plot
p <- qplot(mpg, wt, data = mtcars)
plot_file <- add_ggplot(p)

# Create a table
tab <- gt(head(mtcars))

email <- compose_email(
  body = md(c(
    "## Analysis Results",
    "### Key Metrics",
    render_gt(tab),
    "### Trend Plot",
    plot_file
  ))
)
```

## 3. Sending Emails

```r
tryCatch({
  email |>
    smtp_send(
      to = "recipient@example.com",
      from = Sys.getenv("GMAIL_USERNAME"),
      subject = "Daily Report",
      credentials = creds
    )
  message("Email sent successfully.")
}, error = function(e) {
  cli::cli_abort("Email failed: {e$message}")
})
```

## 4. Integration with Targets

Send an email only if the pipeline succeeds or specific conditions are met.

```r
# _targets.R
list(
  tar_target(report_data, generate_data()),
  
  tar_target(
    email_notification,
    command = {
      send_report_email(report_data)
    },
    cue = tar_cue(mode = "always") # Always try to send if pipeline runs
  )
)
```

## Troubleshooting

-   **Gmail**: Requires an "App Password" if 2FA is enabled.
-   **CI/CD**: Ensure the runner has internet access and port 465/587 is open.
-   **Spam**: Avoid sending too frequently; validate SPF/DKIM records for your domain.
