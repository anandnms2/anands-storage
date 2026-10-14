// Applies Anands Storage branding to a SeaweedFS source tree.
// Usage: node apply-brand.mjs <seaweedfs-src-dir> <brand-dir>
// Every edit asserts that it matched, so the build fails loudly if upstream changes shape.
import fs from "node:fs"
import path from "node:path"

const [src, brand] = process.argv.slice(2)
if (!src || !brand) throw new Error("usage: apply-brand.mjs <seaweedfs-src> <brand-dir>")
const admin = path.join(src, "weed/admin")
const rd = (p) => fs.readFileSync(p, "utf8")
const wr = (p, s) => fs.writeFileSync(p, s)

function edit(file, fn) {
	const p = path.join(src, file)
	const before = rd(p)
	const after = fn(before)
	if (after === before) throw new Error(`brand patch had no effect: ${file}`)
	wr(p, after)
}
// replace first occurrence of `from`, throw if missing
const once = (s, from, to, label) => {
	if (!s.includes(from)) throw new Error(`pattern not found (${label || from.slice(0, 50)})`)
	return s.replace(from, () => to)
}
// templ source has plain quotes; generated _templ.go has them escaped inside Go string literals
const both = (s, from, to, label, goEscaped) => {
	const f = goEscaped ? from.replaceAll('"', '\\"') : from
	const t = goEscaped ? to.replaceAll('"', '\\"') : to
	return once(s, f, t, label)
}

// 1. Static assets
const img = path.join(admin, "static/img")
fs.mkdirSync(img, { recursive: true })
for (const f of ["logo-orange.png", "logo-white.png", "logo-mark.png", "icon-192.png", "icon-512.png", "icon.svg", "favicon-16.png", "favicon-32.png", "apple-touch-icon.png", "site.webmanifest"]) {
	fs.copyFileSync(path.join(brand, f), path.join(img, f))
}
fs.copyFileSync(path.join(brand, "favicon.ico"), path.join(admin, "static/favicon.ico"))

// 2. Theme CSS appended to the admin stylesheet
fs.appendFileSync(path.join(admin, "static/css/admin.css"), rd(path.join(brand, "brand.css")))
fs.writeFileSync(path.join(admin, "static/css/anands.css"), rd(path.join(brand, "brand.css")))

// 3. Layout (navbar, title, footer, login page) in both .templ and generated _templ.go
const NAV_ICON = '<i class="fas fa-server me-2"></i>'
const NAV_IMG = '<img src="/static/img/logo-orange.png" alt="Anands" />'
const ALPHA = '<span class="badge bg-warning text-dark ms-2">ALPHA</span>'
const LOGIN_ICON = '<i class="fas fa-server fa-3x text-primary mb-3"></i>'
const LOGIN_IMG = '<img src="/static/img/logo-orange.png" alt="Anands Storage" class="login-logo mb-3" style="height:72px;width:auto;max-width:100%" />'
const ICON_LINK = '<link rel="icon" href="/static/favicon.ico" type="image/x-icon">'
const ICON_LINKS =
	'<link rel="icon" href="/static/img/icon.svg" type="image/svg+xml">' +
	'<link rel="icon" href="/static/img/favicon-32.png" type="image/png" sizes="32x32">' +
	'<link rel="icon" href="/static/img/favicon-16.png" type="image/png" sizes="16x16">' +
	ICON_LINK +
	'<link rel="apple-touch-icon" href="/static/img/apple-touch-icon.png"><link rel="manifest" href="/static/img/site.webmanifest"><meta name="theme-color" content="#111111">'

for (const [file, goEscaped] of [
	["weed/admin/view/layout/layout.templ", false],
	["weed/admin/view/layout/layout_templ.go", true],
]) {
	edit(file, (s) => {
		s = both(s, NAV_ICON, NAV_IMG, "navbar icon", goEscaped)
		s = both(s, ALPHA, "", "alpha badge", goEscaped)
		s = both(s, LOGIN_ICON, LOGIN_IMG, "login icon", goEscaped)
		s = s.replaceAll(ICON_LINK.replaceAll('"', goEscaped ? '\\"' : '"'), ICON_LINKS.replaceAll('"', goEscaped ? '\\"' : '"'))
		if (!s.includes("apple-touch-icon")) throw new Error("favicon link patch failed in " + file)
		if (!s.includes("SeaweedFS Admin")) throw new Error("title not found in " + file)
		const re = goEscaped ? /<\/head>\s*<body class=\\"bg-light/ : /<\/head>\s*<body class="bg-light/
		if (!re.test(s)) throw new Error("login head not found in " + file)
		const link = goEscaped ? '<link href=\\"/static/css/anands.css\\" rel=\\"stylesheet\\">' : '<link href="/static/css/anands.css" rel="stylesheet">'
		s = s.replace(re, (m) => link + m)
		s = s.replaceAll("SeaweedFS Admin", "Anands Storage")
		return s
	})
}

// 4. Page titles coming from Go handlers
edit("weed/admin/handlers/auth_handlers.go", (s) => once(s, '"SeaweedFS Admin"', '"Anands Storage"', "login title"))
edit("weed/admin/dash/auth_middleware.go", (s) => once(s, '"SeaweedFS Admin Login"', '"Anands Storage Login"', "auth title"))

// 5. Let the admin bind to a chosen address (used so the SSO gate cannot be bypassed in-container)
edit("weed/command/admin.go", (s) =>
	once(
		s,
		'addr := fmt.Sprintf(":%d", *options.port)',
		'addr := fmt.Sprintf("%s:%d", os.Getenv("ANANDS_ADMIN_BIND"), *options.port)',
		"admin listen addr",
	),
)

// 6. SSO mode: /logout ends the session (oauth2-proxy + Authentik), /login jumps straight to the IdP.
//    These routes only exist upstream when the built-in login is on, so no duplicate-route clash.
edit("weed/command/admin.go", (s) =>
	once(
		s,
		"adminHandlers.SetupRoutes(r, authRequired, *options.adminUser, *options.adminPassword, *options.readOnlyUser, *options.readOnlyPassword, enableUI)",
		`adminHandlers.SetupRoutes(r, authRequired, *options.adminUser, *options.adminPassword, *options.readOnlyUser, *options.readOnlyPassword, enableUI)
	if logoutURL := os.Getenv("ANANDS_SSO_LOGOUT_URL"); logoutURL != "" && !authRequired {
		r.GET("/logout", func(c *gin.Context) { c.Redirect(http.StatusFound, logoutURL) })
		r.GET("/login", func(c *gin.Context) { c.Redirect(http.StatusFound, "/oauth2/start?rd=%2F") })
	}`,
		"sso routes",
	),
)

console.log("Anands Storage branding applied")
