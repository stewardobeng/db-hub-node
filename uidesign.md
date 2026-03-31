# CloudDB UI Design Brief

This file is a product-facing UI brief for designers. It is not an implementation spec.

The goal is to redesign the Hub so it feels like a professional infrastructure control plane rather than a flashy demo. The product should look trustworthy, operational, and calm.

## 1. Product Context

CloudDB is a Hub-and-Node MariaDB platform with two primary roles:

- Admin:
  - manages Nodes
  - manages tenant accounts
  - provisions databases on behalf of tenants
  - triggers tenant and full-node backups
  - monitors health and capacity
- Client:
  - logs in to see their databases
  - provisions databases within plan limits
  - downloads `.env` connection files
  - opens phpMyAdmin
  - manages IP allowlists
  - triggers backups for individual databases

There is also a public pre-login experience:

- landing page
- plan selection
- sign up
- login
- payment pending or activation state

## 2. Design Direction

The visual direction should feel like modern B2B infrastructure software.

Avoid:

- all-caps labels everywhere
- neon hacker styling
- overly dramatic gradients
- decorative density that competes with the data
- gaming or cyberpunk aesthetics

Aim for:

- strong hierarchy
- sentence case labels
- professional typography
- restrained color system
- clear table and form design
- confident empty states
- obvious primary actions
- low-friction access to operational details

The UI should feel closer to an enterprise hosting dashboard or cloud database console than a marketing-heavy template.

## 3. Core UX Principles

- Put system status first. Admins should understand health, tenant count, backup state, and pending actions quickly.
- Separate overview pages from detail pages. Lists should summarize; detail pages should explain and allow action.
- Use progressive disclosure. Do not overload the main dashboard with every field.
- Make dangerous actions explicit. Delete, revoke, rotate, or restore actions need clear confirmation.
- Keep connection details easy to retrieve but not visually noisy.
- Use drawers or side panels for fast edits. Use dedicated pages for complex detail views.
- Show system states clearly:
  - healthy
  - warning
  - offline
  - pending
  - expired
  - backup queued
  - backup running
  - backup complete
  - backup failed

## 4. Recommended Information Architecture

### Public Navigation

- Product
- Plans
- Sign in
- Get started

### Admin Navigation

- Overview
- Nodes
- Tenants
- Backups
- Plans
- Activity
- Settings

### Client Navigation

- Overview
- Databases
- Backups
- Account

## 5. Shared Layout Rules

### Desktop Shell

- Left sidebar for primary navigation
- Top bar for page title, global search in future, profile menu, notifications, and quick actions
- Main content area with:
  - page header
  - KPI row
  - primary content block
  - secondary content block or right-side detail panel where needed

### Mobile Shell

- top app bar
- hamburger or bottom navigation
- full-screen sheets instead of narrow modals
- stacked cards instead of wide multi-column tables

### Shared Component Patterns

- KPI cards:
  - value
  - label
  - small context text
  - optional trend or state chip
- Data tables:
  - sticky header on desktop
  - row actions on far right
  - row click opens detail page
- Status chips:
  - healthy
  - warning
  - error
  - queued
  - running
  - complete
  - expired
- Action bar:
  - primary action on the right
  - secondary filters and search on the left
- Drawers:
  - create node
  - edit node
  - create tenant
  - edit tenant
  - backup action confirmation
- Empty states:
  - no nodes
  - no tenants
  - no databases
  - no backups
- Inline alerts:
  - success
  - warning
  - error
- Confirmation dialogs:
  - delete node
  - delete tenant
  - trigger full-node backup
  - provision database

## 6. Public Experience

### 6.1 Landing Page

Purpose:

- explain what the platform is
- show plans
- push visitors to create an account or sign in

Recommended layout:

- top navigation
- hero section:
  - short headline
  - short product value statement
  - primary CTA: get started
  - secondary CTA: sign in
- feature strip:
  - multi-node provisioning
  - backup automation
  - phpMyAdmin access
  - IP allowlists
- plan cards:
  - plan name
  - price
  - number of databases
  - storage quota
  - connection limit
  - CTA per plan
- FAQ / trust section
- footer

Important content:

- keep plan comparison clean
- avoid technical overload on the public page
- focus on value, not internal architecture

### 6.2 Plan Selection / Sign Up Page

Purpose:

- let a user choose a plan and create an account

Recommended layout:

- left side:
  - chosen plan summary
  - plan limits
  - billing note
- right side:
  - account creation form
  - email
  - password
  - optional billing note
- secondary link: already have an account

States:

- billing enabled
- free plan
- validation error
- account exists
- payment pending

### 6.3 Login Page

Purpose:

- single sign-in page for both admin and client users

Recommended layout:

- centered form
- short product line
- email field
- password field
- sign in button
- link to create account
- error message area above form

States:

- invalid credentials
- account pending payment
- account expired
- brute-force lockout

### 6.4 Payment Pending / Activation State

Purpose:

- explain that account activation is waiting for payment confirmation

Recommended layout:

- simple confirmation page
- payment status banner
- explanation text
- link back to login
- support contact or retry guidance

## 7. Admin Experience

## 7.1 Admin Overview Dashboard

Purpose:

- give the admin a fast operational snapshot

Primary content:

- KPI row:
  - active Nodes
  - registered tenants
  - total provisioned databases
  - storage usage summary
  - backup activity summary
- health panel:
  - online vs offline Nodes
  - Nodes with sync errors
  - recent backup queue status
- recent activity feed:
  - node added
  - tenant created
  - database provisioned
  - backup triggered
  - error events
- quick actions:
  - add Node
  - create tenant
  - trigger backup

Recommended arrangement:

- top row of metrics
- left main column for health and activity
- right column for quick actions and attention-needed cards

### 7.2 Nodes List Page

Purpose:

- manage all database Nodes

Top area:

- page title
- short helper text
- primary CTA: add Node
- filters:
  - all
  - healthy
  - warning
  - offline

Main table columns:

- Node name
- database host / IP
- public endpoint
- phpMyAdmin alias
- database count
- last seen
- health
- actions

Row actions:

- view details
- edit
- backup
- delete

Important design notes:

- use row click to open Node detail page
- keep edit and delete in a kebab menu if space is tight
- backup can be a secondary button or menu item
- show disable state for delete when databases still exist

Empty state:

- explain that at least one Node is required before provisioning databases
- CTA: add first Node

### 7.3 Add Node Drawer

Purpose:

- let admin register a new Node quickly without leaving context

Fields:

- display name
- database host / IP
- public endpoint
- agent access token
- phpMyAdmin alias

Support text:

- explain where each value comes from
- especially that `public endpoint` is the base URL only
- explain that `database host / IP` is what goes into the tenant `.env`

Footer actions:

- cancel
- save and test connection

Post-save states:

- Node added and healthy
- Node saved but health check failed

### 7.4 Node Detail Page

Purpose:

- give full context for one Node

Header:

- Node name
- health badge
- last seen timestamp
- primary actions:
  - trigger full backup
  - edit Node

Recommended sections:

- summary cards:
  - database count
  - health
  - backup directory status
  - last backup
- connection details:
  - database host / IP
  - public endpoint
  - phpMyAdmin alias
  - agent restriction
- attached tenant databases table:
  - database name
  - tenant
  - size
  - status
  - actions
- backup history panel:
  - queued
  - running
  - completed
  - failed
- troubleshooting panel:
  - common checks
  - last error

### 7.5 Tenants List Page

Purpose:

- manage all tenant accounts

Top area:

- page title
- primary CTA: create tenant
- filters:
  - all
  - active
  - pending
  - expired

Main table columns:

- tenant email
- plan
- status
- expiry
- database count
- storage used
- last activity
- actions

Row actions:

- view details
- provision database
- backup all tenant databases
- edit
- delete

Important design notes:

- row click should open tenant detail page
- provision should be obvious because it is a core action
- delete should be disabled when databases exist

### 7.6 Create Tenant Drawer

Fields:

- email
- password
- plan
- status
- expiry

Behavior notes:

- if expiry is empty, the system can auto-calculate it from plan duration and status
- show this as helper text, not hidden behavior

### 7.7 Tenant Detail Page

Purpose:

- give complete context for one tenant

Header:

- tenant email
- plan
- status badge
- expiry
- primary actions:
  - provision database
  - backup all databases
  - edit tenant

Recommended sections:

- summary cards:
  - databases used vs limit
  - storage used vs quota
  - plan
  - expiry
- access panel:
  - latest `.env` download if recently generated
  - phpMyAdmin entry guidance
- databases table:
  - database name
  - assigned Node
  - size
  - last backup
  - actions
- account notes:
  - status explanation
  - billing state if later expanded
- recent activity:
  - created
  - updated
  - provisioned
  - backup queued

### 7.8 Backups Center

Purpose:

- give the admin one place to understand backup activity across the platform

This page is strongly recommended even if backup storage browsing is not yet implemented in code.

Recommended layout:

- top summary:
  - backups queued today
  - completed today
  - failed today
  - last successful node-wide backup
- filters:
  - all
  - node backups
  - tenant backups
  - database backups
  - queued
  - complete
  - failed
- backup jobs table:
  - type
  - target
  - Node
  - requested by
  - requested at
  - status
  - file name if available
  - actions

Future-friendly actions:

- view details
- copy restore instructions
- download metadata
- retry backup

### 7.9 Plans Page

Purpose:

- manage product packages and plan limits

This is recommended because plans already exist conceptually and affect signup and provisioning.

Plan card/list fields:

- plan name
- price
- billing duration
- database limit
- storage quota
- max connections
- active tenants count

Actions:

- create plan
- edit plan
- archive plan

### 7.10 Activity / Audit Page

Purpose:

- help the admin understand what happened recently

Recommended content:

- login failures
- node offline alerts
- tenant creation
- database provisioning
- backup requests
- delete attempts

Filters:

- severity
- actor
- entity type
- date range

### 7.11 Settings Page

Purpose:

- house admin-level configuration and operational reference

Recommended sections:

- Hub access:
  - hub URL
  - admin identity
- notifications:
  - SMTP settings summary
  - alert recipient
- billing:
  - Paystack enabled or disabled
  - currency
- credential reference:
  - where to retrieve Node keys
  - restore command
  - help text for add-Node form
- maintenance:
  - watchdog info
  - version info

## 8. Client Experience

### 8.1 Client Overview Dashboard

Purpose:

- give the client a clean summary of account state and database inventory

Top area:

- account status
- plan name
- expiry date
- primary CTA: provision database

Summary cards:

- databases used vs limit
- storage used vs quota
- plan
- expiry

Main content:

- database cards or list
- each database card should show:
  - database name
  - assigned Node
  - size
  - quick actions

Quick actions per database:

- open phpMyAdmin
- download `.env`
- create backup
- manage IP allowlist
- view details

Design note:

- current product only stores the latest generated `.env`, but the design should still make access to credentials feel intentional and easy to find

### 8.2 Client Databases Page

Purpose:

- give a denser, operations-focused view for clients with multiple databases

Recommended table columns:

- database name
- Node
- host
- port
- size
- last backup
- access status
- actions

Filters:

- active
- recently backed up
- by Node

### 8.3 Database Detail Page

Purpose:

- central place for one database

Header:

- database name
- current Node
- status
- primary actions:
  - download `.env`
  - open phpMyAdmin
  - create backup

Recommended tabs or sections:

- connection:
  - host
  - port
  - database
  - username
  - password visibility handling
  - copy actions
- access control:
  - allowed IPs
  - add IP
  - remove IP
  - helper text for `%`
- backups:
  - latest backup state
  - trigger backup
  - restore guidance text
- usage:
  - current size
  - plan quota context

### 8.4 IP Allowlist Management

This can be:

- a section inside database detail, or
- a drawer launched from a database row/card

Recommended UX:

- tokenized list input for IPs and CIDR values
- explanatory text:
  - `localhost` is preserved by the platform
  - `%` means allow any host
- validation feedback inline
- save action with explicit success state

### 8.5 Client Backups Page

Purpose:

- let the client understand backup coverage across their own databases

Recommended content:

- summary:
  - total databases
  - backups queued today
  - last successful backup
- backup list:
  - database
  - requested at
  - status
  - file name if available
  - action

Possible actions:

- view restore instructions
- trigger new backup

### 8.6 Client Account Page

Purpose:

- show plan and account information clearly

Recommended sections:

- plan summary
- status
- expiry
- billing status
- usage summary
- support/help section

If billing is enabled later, this page can also hold:

- payment history
- upgrade or renew CTA

## 9. Important Functional Groupings

Designers should keep these feature clusters together:

### Node Management Cluster

- add Node
- edit Node
- health state
- endpoint details
- backup actions
- attached databases

### Tenant Management Cluster

- create tenant
- edit tenant
- status and expiry
- plan assignment
- provision database
- tenant backup

### Database Access Cluster

- `.env` download
- host
- port
- username
- phpMyAdmin
- IP allowlist

### Backup Cluster

- backup trigger
- queue status
- success/failure state
- backup file reference
- restore instructions

## 10. Recommended Navigation Labels

Use clear sentence case labels.

Good labels:

- Overview
- Nodes
- Tenants
- Backups
- Plans
- Settings
- Account
- Databases
- Create tenant
- Add Node
- Download `.env`
- Open phpMyAdmin
- Manage IP allowlist

Avoid labels like:

- Master Control
- Identity Firewall
- Access Terminal
- Vault Ready

Those are acceptable as marketing language, but not ideal as permanent product navigation labels.

## 11. Form Design Guidance

All form labels and placeholders should use normal case, not uppercase.

Examples:

- `Admin or client email`
- `Choose a secure password`
- `Database host or IP`
- `Public endpoint`
- `Agent access token`
- `phpMyAdmin alias`

Form behavior:

- labels above fields
- helper text below fields
- inline validation
- required fields clearly marked
- destructive or irreversible actions separated visually from save actions

## 12. State Design Requirements

Designers should supply visuals for:

- healthy Node
- offline Node
- Node saved but health check failed
- tenant active
- tenant pending
- tenant expired
- no nodes yet
- no tenants yet
- no databases yet
- no backups yet
- backup queued
- backup complete
- backup failed
- form validation error
- authentication error
- payment pending

## 13. Accessibility And Usability Requirements

- high contrast for tables, forms, and chips
- keyboard-friendly forms and modals
- clear focus states
- color should not be the only signal for health or error
- readable typography at operational density
- all important actions should work well on laptop-sized screens

## 14. Responsive Requirements

Designers should produce desktop and mobile views for:

- landing
- login
- admin overview
- nodes list
- node detail
- tenants list
- tenant detail
- client overview
- database detail

On mobile:

- tables should collapse into stacked cards
- drawers should become full-screen sheets
- sticky bottom action bars are acceptable for primary actions

## 15. Recommended Screen Priority For Design Team

### Phase 1: Must Design First

- landing page
- login page
- sign up / choose plan page
- admin overview
- Nodes list
- add/edit Node drawer
- Node detail
- tenants list
- create/edit tenant drawer
- tenant detail
- backups center
- client overview
- database detail
- client account page

### Phase 2: Strongly Recommended

- plans page
- activity page
- settings page
- payment pending page
- empty/error state library

## 16. Deliverables To Ask From Designers

Ask the UI team for:

- sitemap
- desktop wireframes
- mobile wireframes
- high-fidelity visual system
- table pattern library
- form pattern library
- status chip system
- modal and drawer patterns
- empty state set
- error and success state set
- handoff notes for developer implementation

## 17. Final Design Intent

The redesigned product should feel:

- operational
- credible
- premium
- calm
- efficient

Admins should feel like they are managing infrastructure.

Clients should feel like they are managing their databases, not navigating an abstract control room.
