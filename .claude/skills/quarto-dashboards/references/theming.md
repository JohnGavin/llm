# Theming Reference

## Built-in Themes

```yaml
format:
  dashboard:
    theme: cosmo  # or any of 25 Bootswatch themes
```

Available themes: `default`, `cerulean`, `cosmo`, `cyborg`, `darkly`, `flatly`, `journal`, `litera`, `lumen`, `lux`, `materia`, `minty`, `morph`, `pulse`, `quartz`, `sandstone`, `simplex`, `sketchy`, `slate`, `solar`, `spacelab`, `superhero`, `united`, `vapor`, `yeti`, `zephyr`

## Custom SCSS Theming

Create `custom.scss`:

```scss
/*-- scss:defaults --*/
$body-bg: #fafafa;
$body-color: #333333;
$navbar-bg: #2c3e50;
$navbar-fg: #ffffff;
$link-color: #3498db;
$font-family-sans-serif: "Open Sans", sans-serif;

/*-- scss:rules --*/
.dashboard-header {
  border-bottom: 2px solid $link-color;
}

.card {
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
```

Apply theme:

```yaml
format:
  dashboard:
    theme:
      - cosmo
      - custom.scss
```

## Value Box Color Variables

Customize value box appearance in your SCSS:

```scss
$valuebox-bg-primary: #007bff;
$valuebox-bg-success: #28a745;
$valuebox-bg-info: #17a2b8;
$valuebox-bg-warning: #ffc107;
$valuebox-bg-danger: #dc3545;
```

## Mobile Responsive CSS

```scss
@media (max-width: 768px) {
  .card {
    margin-bottom: 1rem;
  }
}
```

Enable scrolling on mobile:

```yaml
format:
  dashboard:
    scrolling: true
```
