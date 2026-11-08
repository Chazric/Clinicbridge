"""Generates the ClinicBridge AI Word documents. Run: python3 docs/build_docs.py"""
from docx import Document
from docx.shared import Pt, RGBColor
from pathlib import Path

OUT = Path(__file__).parent
NAVY = RGBColor(0x0B, 0x25, 0x45)


def new(title, subtitle):
    d = Document()
    st = d.styles['Normal']; st.font.name = 'Calibri'; st.font.size = Pt(11)
    h = d.add_heading(title, 0)
    for r in h.runs: r.font.color.rgb = NAVY
    d.add_paragraph(subtitle).italic = True
    d.add_paragraph('RED REISHI LLC · ClinicBridge AI · support: redreishilife+clinicbridge@gmail.com')
    return d


def section(d, title, items=None, para=None, level=1):
    d.add_heading(title, level)
    if para: d.add_paragraph(para)
    for i in items or []:
        if isinstance(i, tuple):
            p = d.add_paragraph(style='List Bullet'); p.add_run(i[0] + ' ').bold = True; p.add_run(i[1])
        else:
            d.add_paragraph(i, style='List Bullet')


def table(d, header, rows):
    t = d.add_table(rows=1, cols=len(header)); t.style = 'Light Grid Accent 1'
    for c, h in zip(t.rows[0].cells, header): c.text = h
    for r in rows:
        cells = t.add_row().cells
        for c, v in zip(cells, r): c.text = v
    d.add_paragraph()


# ---------------------------------------------------------------- 1. Recommendations
d = new('Clinical & Product Recommendations', 'Written from the perspective of an internationally practising physician reviewing the CLINICBRIDGE AI directive.')
section(d, 'Verdict', para=(
    'The directive is right to reject “another medical chatbot”. Most preventable harm in hospitals comes from '
    'communication failure: wrong patient, language barriers, lost allergies, unreconciled medicines, results nobody '
    'chased and handoffs where responsibility silently evaporates. ClinicBridge should be judged by one question: '
    '“Did this patient’s critical information arrive intact, verified and owned by a named clinician?” '
    'Everything below serves that question.'))
section(d, 'What this v1 build already does', [
    ('Clinical Truth Ledger —', 'every fact carries provenance (patient-reported, clinician-observed, imported, AI-generated, translated, clinician-approved), verification state, author, time, source, consent reference and an append-only SHA-256 hash chain. Machine content can never be “verified” silently; it must be explicitly approved, and its origin is kept forever.'),
    ('Medical interpreter with safety controls —', '22 languages with dialect/region selection, on-device speech and on-device translation, automatic back-translation, checks that numbers/doses, units, medicine names and negations survived translation, risk classification (consent, serious news, medication, allergy, discharge, symptoms), teach-back confirmation and one-tap escalation to a qualified human interpreter. Consent and serious news ALWAYS escalate.'),
    ('Intelligent handoff —', 'SBAR and I-PASS drafted from the record, every section reviewed by the sender, mandatory medication/allergy check, sender approval, named-receiver acceptance (I-PASS requires the receiver’s synthesis), rejection with reason, and responsibility only transfers on acceptance.'),
    ('Workflow intelligence —', 'missing allergy status, medicines, weight, complaint, code status, pregnancy status (reproductive age), consent, identity; NKDA-vs-allergy contradictions; allergy-vs-medicine and cross-reactivity prompts; duplicate anticoagulant/therapy; high-alert medicines; ISMP “do-not-use” dose notations (trailing zero, naked decimal, U/IU, QD/QOD, µg); conflicting weights; duplicate entries; overdue tasks and pending results; possible duplicate patients (including transposed DOB).'),
    ('Security —', 'AES-256-GCM encrypted vault with the key in the iOS Keychain / Android Keystore, 6+ digit PIN with escalating lockout, Face ID / fingerprint, auto-lock, role-based permissions, hash-chained audit log, screenshot blocking (Android), no cloud backup, retention purge, crypto-shredding “erase all”, passphrase-protected backups.'),
    ('Interoperability —', 'HL7 FHIR R4 Bundle export (Patient, Encounter, AllergyIntolerance, MedicationStatement, Condition, Observation, Task, Composition, Provenance) with base R4 / IPS / US Core / UK Core profile tags.'),
])
section(d, 'My additional clinical recommendations (prioritised)', [
    ('1. Make identity the first gate, not a field.', 'No item, translation or handoff should be accepted for an unverified patient without an explicit “emergency — identity unknown” pathway (temporary ID, later reconciliation). Wrong-patient errors are among the most catastrophic and most preventable events.'),
    ('2. Allergy quality, not just allergy presence.', 'Record reaction type (anaphylaxis vs intolerance), severity, date and source. ~90% of reported penicillin allergies are not true IgE allergy; offer a structured PEN-FAST style prompt so the record supports de-labelling by an allergist rather than lifelong broad-spectrum antibiotics.'),
    ('3. Medication reconciliation as a first-class workflow.', 'Best Possible Medication History from at least two sources (patient + pharmacy/GP list/bottles), with each medicine marked continue / hold / stop / changed and a named reconciler. Transitions of care are where most medication errors occur.'),
    ('4. Weight and units discipline.', 'Weight in kg only, measured vs stated vs estimated, with date. Paediatric and renal dosing errors start with wrong weights. Flag any weight change >10% between entries (already partly implemented as conflict detection).'),
    ('5. Closed-loop results.', 'Every pending investigation must have an owner, an expected time and an acknowledgement. Results pending at discharge are a top source of missed diagnoses — they must appear in the discharge handoff and the patient summary.'),
    ('6. Teach-back is a safety measure, not a courtesy.', 'For discharge instructions, new medicines and red-flag symptoms, require teach-back with the patient’s own words recorded (translated) before the item is marked communicated.'),
    ('7. Human interpreters remain the standard.', 'Use machine translation for routine logistics and to bridge waiting time; use qualified interpreters (in person, video or phone) for consent, capacity, serious news, mental health, safeguarding, paediatrics and discharge. Never use family members—especially children—as interpreters for clinical content.'),
    ('8. Sepsis / deterioration hand-off cues.', 'Allow structured early-warning scores (NEWS2 / PEWS / MEOWS) to be recorded as observations with provenance; the handoff should show the trend, not just the latest value. ClinicBridge should display, never calculate a treatment decision.'),
    ('9. Code status & goals of care.', 'Code status must be explicitly documented (Full / DNACPR / limited) with who discussed it, with whom, and when; it should headline every handoff.'),
    ('10. Pregnancy and lactation status.', 'Required before imaging with ionising radiation and teratogenic medicines for anyone of reproductive potential, documented without assumptions about gender identity.'),
    ('11. Paediatric mode.', 'Weight-based context, guardian identity and consent, age-appropriate pain scales (FLACC / Wong-Baker) and safeguarding flags restricted to authorised roles.'),
    ('12. Mental capacity & consent records.', 'Distinguish verbal, written and implied consent; who obtained it, interpreter used (ID), and capacity assessment where relevant. Consent via machine translation alone should be blocked (already enforced as mandatory escalation).'),
    ('13. Alert fatigue governance.', 'Track every alert shown, acknowledged or overridden. Retire alerts with high override and low yield; this is how real hospitals keep safety alerts trusted.'),
    ('14. Downtime and offline safety.', 'Clinics lose connectivity. Keep the app fully usable offline (already device-first) and add a printable/QR emergency summary for downtime.'),
    ('15. Global health realities.', 'Low-bandwidth mode, Android-first support for low-cost devices, shared-device mode with quick user switching, and SMS/WhatsApp-free design for patient data (consumer messaging is not an approved clinical channel).'),
    ('16. Equity and bias.', 'Measure translation quality per language and dialect, not overall. Publish performance for low-resource languages (Haitian Creole, Swahili, Tagalog, etc.) and restrict features where accuracy is unproven.'),
    ('17. Patient-facing summary.', 'Plain-language summary in the patient’s language, at a 6th-grade reading level, with medication list, follow-up, red flags and who to call — reviewed by a clinician before it is shared.'),
])
section(d, 'Product & business recommendations', [
    ('Go-to-market:', 'Start with emergency departments, urgent care and inpatient wards with high limited-English-proficiency populations; hospital interpreter services and patient-safety officers are the buyers, nursing is the champion.'),
    ('Pricing:', 'Per-clinician seat for clinics; enterprise licence per facility with EHR integration, SSO and audit export. Free individual app for evaluation using synthetic data only.'),
    ('Integrations next:', 'SMART on FHIR launch (Epic, Oracle Health/Cerner, MEDITECH), HL7v2 ADT feed for identity, IHE PIX/PDQ for patient matching, OAuth2/OIDC SSO with the hospital identity provider, MDM (Intune/Jamf) for managed devices.'),
    ('AI roadmap:', 'Ambient scribe drafts are allowed only as AI-generated ledger items; add a medical-terminology-tuned translation model with per-language validation; never let a model output become “verified” without approval (architecture already enforces this).'),
    ('Do not:', 'store data in consumer cloud backups, ship real patient data in demos, market it as diagnostic, or claim interpreter equivalence.'),
])
d.save(OUT / 'ClinicBridge_Recommendations.docx')

# ---------------------------------------------------------------- 2. Regulatory & compliance
d = new('Regulatory & Compliance Notes', 'Not legal advice. Confirm with regulatory counsel in every market before clinical deployment.')
section(d, 'Intended use (draft)', para=(
    'ClinicBridge AI is a clinical communication and documentation support tool for licensed healthcare '
    'professionals. It organises patient-reported, clinician-entered and imported information, supports medical '
    'interpretation and structured handoff, and highlights missing or conflicting documentation. It does not '
    'diagnose, recommend treatment, calculate doses, or replace professional interpreters or clinical judgement.'))
section(d, 'Software as a Medical Device (SaMD) position', [
    ('United States (FDA):', 'The intended use above is designed to fall outside device regulation under the 21st Century Cures Act §3060 / Clinical Decision Support guidance (displays and organises information for an HCP who can independently review the basis). Medication cross-reactivity prompts are “basis visible” and not patient-specific dosing. If future features compute scores, doses or diagnoses, a 510(k)/De Novo pathway assessment is required.'),
    ('European Union (MDR 2017/745):', 'Rule 11 classifies most decision-informing software as Class IIa or higher. Communication/translation/handoff functions alone are likely not medical devices, but the allergy/medication conflict prompts could be argued as such. Obtain a qualification opinion; consider separating those prompts into a configurable module.'),
    ('United Kingdom:', 'MHRA UKCA / Software and AI as a Medical Device change programme; NHS DTAC assessment and DCB0129 (manufacturer clinical safety case) and DCB0160 (deploying organisation) are expected by NHS buyers. A named Clinical Safety Officer is required.'),
    ('Canada, Australia, others:', 'Health Canada SaMD guidance and TGA software-based medical device rules apply similar risk-based tests.'),
])
section(d, 'Privacy and security frameworks', [
    ('HIPAA (US):', 'Hospitals will require a Business Associate Agreement once any server-side processing exists. v1 is device-only (no RED REISHI servers receive PHI).'),
    ('GDPR / UK GDPR:', 'Health data is special category data; requires DPIA, lawful basis (Art. 6(1)(e)/9(2)(h)), data minimisation, retention limits (implemented), right to erasure (implemented per patient and full device).'),
    ('Other:', 'PIPEDA/PHIPA (Canada), LGPD (Brazil), POPIA (South Africa), Australian Privacy Act, India DPDP Act — configure retention and data residency per country.'),
    ('Security standards to target:', 'OWASP MASVS L2, ISO 27001 / SOC 2 Type II for the company, ISO 14971 risk management, IEC 62304 software lifecycle, IEC 82304-1 health software.'),
])
section(d, 'Interpreter services law', [
    'US: Title VI of the Civil Rights Act and ACA §1557 require qualified interpreters for limited-English-proficiency patients; machine translation does not satisfy the requirement on its own. ClinicBridge therefore positions machine translation as a bridge and enforces human escalation for consent and serious news.',
    'Record interpreter identity (name/ID, service, modality) for consent conversations.',
])
section(d, 'App store requirements', [
    'Apple App Store Review Guideline 1.4.1 (medical apps): must disclose methodology and not claim diagnostic accuracy; 5.1.1/5.1.3 health data rules — no advertising, no data mining, no iCloud storage of personal health info.',
    'Google Play Health apps policy and Health Apps declaration; Data safety form (see Store Listings document); medical device disclaimer where applicable.',
    'Both stores: demo/review account must use synthetic data — use the built-in “Load synthetic demo” option and provide the PIN in review notes.',
])
d.save(OUT / 'ClinicBridge_Regulatory_Notes.docx')

# ---------------------------------------------------------------- 3. Benchmarks & validation
d = new('Benchmarks, Validation & Test Plan', 'What has been verified, and how ClinicBridge should be measured before clinical use.')
section(d, 'Verified in this build (automated)', para='flutter analyze: no issues. flutter test: 38/38 unit tests pass, covering:')
table(d, ['Area', 'What the tests prove'], [
    ['Clinical Truth Ledger', 'Provenance preserved; AI/translated items cannot be verified without approval; approval keeps origin; amendments require reasons; retractions stay in history; tampering any entry breaks the hash chain.'],
    ['Role-based access', 'Viewer cannot write/export; interpreter cannot approve machine content; administrator cannot write clinical facts.'],
    ['Workflow intelligence', 'Missing data, NKDA conflict, penicillin–amoxicillin, cephalosporin cross-reactivity, duplicate anticoagulants, high-alert medicines, unsafe dose notation, conflicting weights, overdue tasks, duplicate patients.'],
    ['Interpreter safety', 'Number/dose mismatch, dropped negation, missing drug name, low agreement and consent/serious-news risk all force human-interpreter escalation.'],
    ['Handoff', 'Cannot send without section review + meds/allergy check; only named receiver accepts; I-PASS requires synthesis; responsibility transfers only on acceptance; rejection returns to draft.'],
    ['FHIR', 'Bundle structure, resource types, Provenance with ledger hash, synthetic tag.'],
    ['Security', 'Vault ciphertext contains no plaintext, wrong key fails, .bak recovery, backup passphrase, PIN strength rules and lockout, retention purge, patient deletion isolation.'],
])
section(d, 'Benchmarks to run before clinical pilots', [
    ('Translation quality per language pair:', 'Back-translation agreement is a heuristic, not accuracy. Run blinded bilingual clinician review (e.g., 200 clinical phrases × each language, rate meaning-preserved / minor / critical error). Target: critical-error rate <1% for supported pairs; disable pairs that fail.'),
    ('Critical-element preservation:', 'Numbers, doses, units, negation, laterality (left/right), time expressions. Target 100% detection of altered numbers in test set.'),
    ('Speech recognition:', 'Word-error rate per language and accent in noisy ward conditions; medication-name recognition rate.'),
    ('Handoff quality:', 'I-PASS validated observation tool; measure omissions of pending results, code status and allergies pre/post deployment (I-PASS study showed ~23% reduction in medical errors with structured handoff).'),
    ('Alert performance:', 'Positive predictive value and override rate per alert type; time-to-acknowledge.'),
    ('Usability:', 'System Usability Scale (target >75), time to complete admission documentation, taps-to-handoff.'),
    ('Security:', 'Independent OWASP MASVS L2 penetration test; dependency vulnerability scanning in CI.'),
    ('Accessibility:', 'VoiceOver/TalkBack, dynamic type up to 200%, colour contrast (WCAG 2.2 AA).'),
])
section(d, 'Current limitations (honest status)', [
    'Device-only: no EHR connection, no server sync, no multi-device sharing; handoff between two clinicians works on a shared device or via FHIR export.',
    'On-device ML Kit translation is general-purpose, not medical-grade; it is labelled and gated accordingly.',
    'Drug knowledge is a small curated safety list, not a licensed drug database.',
    'iOS build must be compiled and signed on macOS with Xcode (not verified on this Linux build machine).',
])
d.save(OUT / 'ClinicBridge_Benchmarks_and_Validation.docx')

# ---------------------------------------------------------------- 4. Roadmap
d = new('Roadmap', 'From device-only prototype to an internationally deployable clinical platform.')
table(d, ['Phase', 'Scope', 'Exit criteria'], [
    ['v1.0 (this build)', 'Device-only encounter workspace, ledger, interpreter, SBAR/I-PASS, alerts, encryption, FHIR export, synthetic demo.', 'Store-ready builds, internal clinical review, synthetic-data usability tests.'],
    ['v1.1', 'Structured allergy reactions, medication reconciliation workflow, NEWS2/PEWS observations, code-status headline, printable/QR downtime summary, alert analytics.', 'Clinical Safety Officer sign-off on hazard log.'],
    ['v1.2', 'Patient-facing translated summary with clinician review; interpreter ID capture; paediatric mode.', 'Bilingual clinician translation benchmark passed for launch languages.'],
    ['v2.0', 'Secure backend (end-to-end encrypted sync), multi-device handoff, SSO (OIDC/SAML), MDM, organisation admin console, audit export.', 'SOC 2 Type I, pen test, DPIA, BAA template.'],
    ['v2.1', 'SMART on FHIR launch & write-back (Epic, Oracle Health, MEDITECH), HL7v2 ADT, IHE PIX/PDQ patient matching, country profiles (US Core, UK Core, IPS, AU Base).', 'Integration certification with first hospital partner.'],
    ['v3.0', 'Medical-tuned translation/speech models with per-language validation, ambient scribe as AI-generated ledger items, licensed drug database.', 'Regulatory qualification decision per market; clinical pilot outcomes published.'],
])
d.save(OUT / 'ClinicBridge_Roadmap.docx')

# ---------------------------------------------------------------- 5. Store listings
d = new('App Store & Google Play Listings', 'Copy-ready metadata for App Store Connect and Google Play Console.')
section(d, 'Common', [
    ('App name:', 'ClinicBridge AI'),
    ('Subtitle (iOS, 30):', 'Clinical encounters & handoff'),
    ('Short description (Play, 80):', 'Interpreter, clinical truth ledger and safe handoff for clinicians.'),
    ('Bundle / package ID:', 'com.redreishi.clinicbridge'),
    ('Category:', 'Medical (primary), Productivity (secondary)'),
    ('Age rating:', '17+ (iOS: Medical/Treatment Information) / Play: Everyone with medical content — target audience: healthcare professionals 18+'),
    ('Price:', 'Free (enterprise licences sold separately)'),
    ('Support:', 'redreishilife+clinicbridge@gmail.com'),
    ('Privacy policy URL:', 'https://chazric.github.io/ClinicBridge/privacy.html (host the included privacy.html)'),
    ('Keywords (iOS, 100):', 'clinical,handoff,SBAR,IPASS,interpreter,nurse,doctor,medical translation,FHIR,patient safety'),
])
section(d, 'Full description', para=(
    'ClinicBridge AI keeps every patient encounter understood, communicated, organised and transferred with '
    'traceable clinical information.\n\n'
    '• MEDICAL INTERPRETER WITH SAFETY CONTROLS — speak with patients in 22 languages and regional dialects. '
    'Speech and translation run on the device. Every translation is back-translated and checked for changed numbers, '
    'doses, units, medicine names and dropped negations. Consent and serious conversations are routed to a qualified '
    'human interpreter.\n'
    '• CLINICAL TRUTH LEDGER — every fact shows where it came from (patient-reported, clinician-observed, imported, '
    'AI-generated, translated), who recorded it, when, and every change since. Machine-generated content stays '
    'labelled until a clinician approves it.\n'
    '• SAFE HANDOFF — SBAR and I-PASS handoffs with outstanding tasks, pending results and medication/allergy '
    'verification. Responsibility only transfers when the receiving clinician accepts.\n'
    '• WORKFLOW ALERTS — missing allergies, weight, code status, consent or identity; allergy–medicine conflicts; '
    'duplicate therapy; unsafe dose abbreviations; overdue tasks; possible duplicate patients.\n'
    '• SECURITY — AES-256 encryption, Face ID / fingerprint and PIN lock, role-based access, tamper-evident audit log, '
    'no cloud backup, retention and secure erase. HL7 FHIR R4 export.\n\n'
    'Includes a synthetic demo workspace. Never enter real patient data in demo mode.\n\n'
    'ClinicBridge AI is a communication and documentation tool for healthcare professionals. It does not diagnose, '
    'prescribe or replace clinical judgement or qualified interpreters.'))
section(d, 'Apple App Privacy (“nutrition label”)', [
    'Data collected by RED REISHI LLC: None. All patient and clinician data stays encrypted on the device.',
    'Tracking: No. Third-party advertising/analytics SDKs: none.',
    'Note: on-device ML Kit downloads language models from Google; no patient text is sent.',
])
section(d, 'Google Play Data safety', [
    'Data shared with third parties: No.',
    'Data collected: No (data processed only on device; not transmitted to developer).',
    'Encrypted in transit: N/A (no transmission of user data). Users can request deletion: Yes — in-app “Erase all data”.',
    'Health apps declaration: Clinical / healthcare-provider workflow tool; not a medical device.',
    'Permissions: Microphone (speech-to-text for interpretation), Biometric (unlock), Internet (download translation language models only).',
])
section(d, 'Review notes for Apple / Google', para=(
    'On first launch choose “Load synthetic demo data”, set PIN 147258, select “Dr. Ada Okafor (Physician)”. '
    'All patients are fictional. To try the interpreter, open Maria Garcia Lopez → translate icon. '
    'To try handoff, open Jean-Baptiste Pierre → Handoff tab, then switch profile to the receiver to accept.'))
section(d, 'Screenshots', para='Phone screenshots captured from the Android build are in the screenshots/ folder of the ZIP. iOS 6.7"/6.9" screenshots must be captured from the iOS simulator on macOS.')
d.save(OUT / 'ClinicBridge_Store_Listings.docx')
print('docs written')
