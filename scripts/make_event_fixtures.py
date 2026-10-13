#!/usr/bin/env python3
"""Render the AI-add test screenshots (fictional emails, event pages, chats, tickets, posters)
with headless Chrome into Tests/Fixtures/EventImages. Cases assume "now" is Mon 12 Oct 2026, 14:00, Europe/Prague."""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Tests/Fixtures/EventImages"
# Full Chrome can keep running after a headless screenshot; prefer a headless shell when one is installed.
SHELLS = sorted(Path.home().glob(".cache/*/chrome/chrome-headless-shell/*/*/chrome-headless-shell"))
CHROME = str(SHELLS[-1]) if SHELLS else "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

BASE = """
<style>
* { box-sizing: border-box; }
body { margin: 0; font: 15px/1.45 -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1f2328; background: #fff; }
.mail { max-width: 860px; margin: 0 auto; padding: 28px 36px; }
.mail h1 { font-size: 22px; font-weight: 600; margin: 0 0 14px; }
.meta { display: flex; gap: 12px; align-items: center; border-bottom: 1px solid #e5e7eb; padding-bottom: 14px; margin-bottom: 18px; }
.avatar { width: 40px; height: 40px; border-radius: 50%; display: grid; place-items: center; color: #fff; font-weight: 700; }
.small { color: #6b7280; font-size: 13px; }
.box { border: 1px solid #e5e7eb; border-radius: 10px; padding: 16px 18px; background: #f9fafb; margin: 16px 0; }
.btn { display: inline-block; background: #2563eb; color: #fff; padding: 9px 16px; border-radius: 8px; font-weight: 600; }
.toolbar { background: #f3f4f6; border-bottom: 1px solid #e5e7eb; padding: 9px 16px; font-size: 13px; color: #6b7280; }
</style>
"""


def mail(subject, sender, address, color, sent, body):
    return f"""{BASE}<div class="toolbar">Inbox › {subject}</div><div class="mail"><h1>{subject}</h1>
    <div class="meta"><div class="avatar" style="background:{color}">{sender[0]}</div>
    <div><b>{sender}</b> <span class="small">&lt;{address}&gt;</span><div class="small">to me · {sent}</div></div></div>{body}</div>"""


CASES = {
    "email_dentist": (1000, 760, 1, mail(
        "Appointment reminder", "Smile Studio Vinohrady", "noreply@smilestudio-example.cz", "#0ea5e9", "Mon, 12 Oct, 08:02",
        """<p>Dear patient,</p><p>This is a friendly reminder of your upcoming check-up with <b>MUDr. Jana Novák</b>.</p>
        <div class="box"><b>Thursday, 15 October</b><br>9:40 AM<br>Smile Studio Vinohrady, Korunní 48, Praha 2</div>
        <p>Please arrive 10 minutes early and bring your insurance card. To reschedule, call +420 222 000 111 at least 24 hours ahead.</p>
        <p class="small">You received this email because you booked online on 2 Sep 2026.</p>""")),
    "email_flight": (1000, 900, 1, mail(
        "Your booking is confirmed – PRG to LHR", "Skyline Air", "bookings@skyline-air.example", "#7c3aed", "Sat, 10 Oct, 21:15",
        """<p>Thanks for flying with us! Booking reference <b>QX7T2M</b>.</p>
        <div class="box"><div class="small">OUTBOUND · Saturday 24 October 2026</div>
        <div style="display:flex;justify-content:space-between;align-items:center;margin-top:8px">
        <div><div style="font-size:30px;font-weight:700">07:05</div>Prague (PRG)<br><span class="small">Terminal 1</span></div>
        <div class="small">SK 857 · 2h 15m · Direct</div>
        <div style="text-align:right"><div style="font-size:30px;font-weight:700">08:20</div>London Heathrow (LHR)<br><span class="small">Terminal 5</span></div></div>
        <p class="small" style="margin-bottom:0">All times are local to each airport.</p></div>
        <p>Online check-in opens 24 hours before departure. Bag drop closes 40 minutes before departure.</p>
        <span class="btn">Manage booking</span>""")),
    "web_meetup": (1200, 820, 1, f"""{BASE}<div style="background:#111827;color:#fff;padding:14px 32px;font-weight:700">meetspace</div>
        <div style="max-width:1040px;margin:0 auto;padding:30px;display:grid;grid-template-columns:1.6fr 1fr;gap:30px">
        <div><div class="small">Swift Prague · Hosted by Tomáš K.</div><h1 style="font-size:34px;margin:6px 0 16px">Swift Prague Meetup #42: Concurrency in practice</h1>
        <div style="height:220px;border-radius:12px;background:linear-gradient(135deg,#f97316,#ec4899)"></div>
        <h3>Details</h3><p>Two talks on Swift 6 strict concurrency, then pizza and drinks. Bring your laptop if you want to follow along.</p>
        <p class="small">78 attendees · 12 spots left</p></div>
        <div><div class="box"><b>📅 Wednesday, November 4, 2026</b><br>6:30 PM to 9:00 PM CET<br><br><b>📍 Impact Hub Karlín</b><br>Pernerova 676/51, Praha 8</div>
        <span class="btn" style="display:block;text-align:center">Attend</span></div></div>"""),
    "web_webinar_et": (1100, 700, 1, f"""{BASE}<div style="background:linear-gradient(90deg,#0f766e,#0e7490);color:#fff;padding:50px 60px">
        <div style="letter-spacing:.12em;font-size:13px;font-weight:700">LIVE WEBINAR</div>
        <h1 style="font-size:38px;margin:10px 0">Scaling Postgres Without Tears</h1>
        <div style="font-size:19px">Tuesday, October 20, 2026 · 11:00 AM ET · 60 minutes</div></div>
        <div style="padding:30px 60px;max-width:900px"><p>Join our principal engineer for a deep dive into partitioning, connection pooling and query plans.
        Can't make it live? Register anyway and we'll send you the recording.</p>
        <div class="box">Register by <b>October 19</b> to receive the join link. Hosted on Zoom.</div><span class="btn">Save my seat</span></div>"""),
    "chat_slack": (900, 560, 2, f"""{BASE}<div style="display:flex;height:100vh"><div style="width:200px;background:#3f0e40;color:#d6c7d6;padding:16px;font-size:14px">
        <b style="color:#fff">Acme Studio</b><p># general<br><b style="color:#fff"># project-atlas</b><br># random</p></div>
        <div style="flex:1;padding:16px 22px"><b># project-atlas</b><div style="border-bottom:1px solid #eee;margin:10px -22px 14px"></div>
        <div style="display:flex;gap:10px;margin-bottom:16px"><div class="avatar" style="background:#16a34a;border-radius:8px">M</div>
        <div><b>Martina</b> <span class="small">13:41</span><br>hey, the client pushed back on today's review 😅</div></div>
        <div style="display:flex;gap:10px"><div class="avatar" style="background:#16a34a;border-radius:8px">M</div>
        <div><b>Martina</b> <span class="small">13:42</span><br>can we move the Atlas design sync to tomorrow 3pm instead? 45 min should be enough. I'll send the Meet link</div></div></div></div>"""),
    "sms_haircut": (420, 760, 2, f"""{BASE}<div style="background:#f2f2f7;height:100vh;padding:14px">
        <div style="text-align:center;font-size:13px;color:#8e8e93">Salon Bára<br>Text Message · Today 11:05</div>
        <div style="margin-top:18px;background:#e5e5ea;border-radius:18px;padding:10px 14px;max-width:80%">Hi! Confirming your haircut next Friday at 17:30 with Bára 💇‍♀️ Reply YES to confirm.</div>
        <div style="margin:10px 0 0 auto;background:#0b84fe;color:#fff;border-radius:18px;padding:10px 14px;max-width:40%;text-align:right">YES</div>
        <div style="margin-top:10px;background:#e5e5ea;border-radius:18px;padding:10px 14px;max-width:80%">Perfect, see you then! Salon Bára, Mánesova 12</div></div>"""),
    "poster_concert": (700, 980, 1, """<div style="height:100vh;background:#0b0b0f;color:#f5f5f5;font-family:Impact,'Arial Black',sans-serif;padding:50px;position:relative;overflow:hidden">
        <div style="position:absolute;right:-120px;top:-80px;width:460px;height:460px;border-radius:50%;background:#e11d48;opacity:.8"></div>
        <div style="position:relative;font-size:26px;letter-spacing:.2em">LIVE IN PRAGUE</div>
        <div style="position:relative;font-size:110px;line-height:.95;margin-top:40px">THE<br>PAPER<br>KITES*</div>
        <div style="position:relative;font-size:60px;margin-top:60px;color:#fde047">FRI 13.11.</div>
        <div style="position:relative;font:600 26px Arial;margin-top:16px">DOORS 19:00 &nbsp;/&nbsp; SHOW 20:00</div>
        <div style="position:relative;font:600 30px Arial;margin-top:30px">LUCERNA MUSIC BAR</div>
        <div style="position:relative;font:14px Arial;margin-top:60px;opacity:.6">*tribute night · tickets at the door 390 CZK</div></div>"""),
    "email_weekday_conflict": (1000, 640, 1, mail(
        "Quarterly planning – save the date", "Lukáš Dvořák", "lukas@northwind-example.cz", "#ea580c", "Fri, 9 Oct, 16:40",
        """<p>Hi all,</p><p>Please block <b>Monday, 3 November 2026, 10:00–12:00</b> for our quarterly planning. We'll meet in the big room on the 4th floor.</p>
        <p>Agenda to follow next week.</p><p>Thanks,<br>Lukáš</p>""")),
    "ticket_train": (1000, 520, 1, f"""{BASE}<div style="margin:30px;border:2px dashed #94a3b8;border-radius:14px;padding:26px;font-family:Menlo,monospace">
        <div style="display:flex;justify-content:space-between"><b style="font-size:20px">ČD · JÍZDENKA / TICKET</b><span>Doklad č. 4471 2209 8810</span></div>
        <table style="width:100%;margin-top:22px;font-size:16px;border-collapse:collapse">
        <tr><td class="small">Datum</td><td class="small">Odjezd</td><td class="small">Příjezd</td><td class="small">Vlak</td><td class="small">Vůz/Místo</td></tr>
        <tr style="font-size:20px"><td><b>30.10.2026</b></td><td><b>14:12</b> Praha hl.n.</td><td><b>16:49</b> Brno hl.n.</td><td>EC 173</td><td>255 / 64</td></tr></table>
        <p class="small" style="margin-top:22px">2. třída · Dospělý · Cena 279 Kč · Zakoupeno 12.10.2026 09:51</p></div>"""),
    "email_ambiguous_date": (1000, 620, 1, mail(
        "Workshop invite: Design Systems 101", "Rachel Moore", "rachel@brightlabs-example.com", "#db2777", "Mon, 12 Oct, 03:12",
        """<p>Hi there,</p><p>Our next online workshop is on <b>11/06/2026 at 2 pm CET</b>. It runs for about 90 minutes and we'll share the Zoom link the day before.</p>
        <p>Cheers,<br>Rachel<br><span class="small">Bright Labs · Boston, MA</span></p>""")),
    "web_conference_schedule": (1100, 860, 1, f"""{BASE}<div style="padding:34px 50px;max-width:980px"><div class="small">DEVFEST PRAHA 2026 · YOUR AGENDA</div>
        <h1 style="font-size:30px">My saved sessions</h1>
        <h3 style="margin-top:26px">Saturday 7 November</h3>
        <div class="box" style="display:flex;gap:24px"><b style="width:120px">09:30–10:15</b><div><b>Opening keynote: The next decade of the web</b><br><span class="small">Main hall</span></div></div>
        <div class="box" style="display:flex;gap:24px"><b style="width:120px">13:00–15:00</b><div><b>Workshop: On-device ML with Core ML</b><br><span class="small">Room B2 · bring a laptop</span></div></div>
        <h3 style="margin-top:26px">Sunday 8 November</h3>
        <div class="box" style="display:flex;gap:24px"><b style="width:120px">16:00–17:00</b><div><b>Closing panel: Building calmer software</b><br><span class="small">Main hall</span></div></div>
        <p class="small">Venue: O2 universum, Českomoravská 2345/17a, Praha 9</p></div>"""),
    "web_festival_allday": (1100, 640, 1, f"""{BASE}<div style="height:100vh;background:#fef3c7;padding:60px">
        <div style="font-size:16px;font-weight:700;letter-spacing:.2em">INTERNATIONAL DESIGN FESTIVAL</div>
        <div style="font-size:80px;font-weight:800;line-height:1;margin:16px 0">Designblok '26</div>
        <div style="font-size:30px">21—25 October 2026</div><div style="font-size:22px;margin-top:8px">Výstaviště Praha, Holešovice</div>
        <p style="max-width:640px;margin-top:30px">Five days of exhibitions, talks and studio showcases. Daily 10:00–20:00.</p></div>"""),
    "email_noisy_dinner": (1000, 820, 1, mail(
        "Re: Team dinner 🍽️", "Eva Horáková", "eva@northwind-example.cz", "#059669", "Mon, 12 Oct 2026, 09:14",
        """<p>Booked it! <b>Friday 23 Oct, 7.30pm at Lokál Dlouhá</b>, table under my name for 9 people.</p>
        <p>Please RSVP by Oct 16 so I can confirm the final headcount. Reminder that the budget sync on Oct 14 is cancelled.</p>
        <div style="border-left:3px solid #e5e7eb;padding-left:12px;color:#6b7280;margin-top:20px">On Thu, 8 Oct 2026 at 17:20, Petr wrote:<br>
        &gt; Shall we do the dinner the week after next? Thursday or Friday works for me.</div>""")),
    "web_deploy_overnight": (1000, 560, 1, f"""{BASE}<div style="padding:30px 44px"><div style="background:#fee2e2;color:#991b1b;padding:12px 16px;border-radius:8px;font-weight:600">⚠ Scheduled maintenance</div>
        <h1 style="font-size:26px">Production database migration</h1>
        <p>Maintenance window: <b>Sat 31 Oct, 23:00 – 02:00</b> (Prague time). The API will be read-only during this window.</p>
        <p class="small">Status page · Posted 12 Oct 2026 by the Platform team</p></div>"""),
    "email_thread_changed": (1000, 900, 1, mail(
        "Re: Re: Contract review", "Ondřej Svoboda", "ondrej@lawfirm-example.cz", "#0891b2", "Mon, 12 Oct, 12:31",
        """<p>Sure, 4:30 works for me too. Same room.</p><p>O.</p>
        <div style="border-left:3px solid #e5e7eb;padding-left:12px;color:#6b7280;margin-top:18px">On Mon, 12 Oct 2026 at 11:02, you wrote:<br>
        &gt; Something came up, could we push it to 4:30 the same day?<br><br>
        On Fri, 9 Oct 2026 at 15:47, Ondřej Svoboda wrote:<br>&gt; Let's go through the contract on Thursday at 2pm in meeting room 3, about an hour.</div>""")),
    "web_dst_et": (1100, 600, 1, f"""{BASE}<div style="padding:40px 60px"><div class="small">ONLINE EVENT</div>
        <h1 style="font-size:34px">Product Launch Livestream</h1>
        <div class="box" style="font-size:18px">🗓 Wednesday, October 28, 2026<br>🕙 10:00 AM – 11:00 AM ET</div>
        <p>Streaming on YouTube and LinkedIn. Add to calendar to get a reminder.</p></div>"""),
    "note_handwritten": (700, 560, 2, """<div style="height:100vh;background:#a3a3a3;display:grid;place-items:center">
        <div style="width:440px;height:400px;background:#fef08a;transform:rotate(-3deg);box-shadow:0 10px 30px rgba(0,0,0,.35);padding:34px;
        font-family:'Bradley Hand','Noteworthy','Marker Felt',cursive;font-size:38px;line-height:1.35;color:#1e3a8a">
        Vet – Max 🐶<br>tue 20/10<br>@ 8:45<br><span style="font-size:26px">bring vaccination card!</span></div></div>"""),
    "invite_utc": (1000, 560, 1, f"""{BASE}<div style="padding:30px 44px"><h1 style="font-size:24px">Invitation: Infra incident review</h1>
        <table style="font-size:16px;border-collapse:collapse"><tr><td class="small" style="padding:6px 20px 6px 0">When</td>
        <td>Thu Nov 5, 2026 9:00am – 10:00am (Coordinated Universal Time)</td></tr>
        <tr><td class="small" style="padding:6px 20px 6px 0">Where</td><td>https://meet.example.com/abc-defg-hij</td></tr>
        <tr><td class="small" style="padding:6px 20px 6px 0">Organizer</td><td>sre-team@acme-example.com</td></tr></table>
        <p style="margin-top:20px"><span class="btn">Yes</span> &nbsp; <span class="btn" style="background:#6b7280">Maybe</span> &nbsp; <span class="btn" style="background:#6b7280">No</span></p></div>"""),
    # Tiered benchmark additions.
    "web_restaurant_booking": (1000, 620, 1, f"""{BASE}<div style="padding:34px 50px;max-width:900px"><div style="font-size:40px">✅</div>
        <h1 style="font-size:28px">Your table is booked</h1><div class="box" style="font-size:17px">
        <b>U Modré kachničky</b><br>Saturday, 17 October 2026 · 19:00<br>4 guests · Nebovidská 6, Praha 1</div>
        <p class="small">Booking ref. TB-55102 · Please let us know if you're running more than 15 minutes late.</p></div>"""),
    "email_reschedule_confirmed": (1000, 720, 1, mail(
        "Design review moved to Friday", "Hana Králová", "hana@northwind-example.cz", "#9333ea", "Mon, 12 Oct, 10:12",
        """<p>Hi,</p><p>Quick update: we've had to move the design review from Wednesday to <b>Friday, same time</b>. Room stays the same.</p>
        <p>Hana</p><div class="box"><div class="small">ORIGINAL INVITE</div><b>Design review</b><br>Wednesday 14 October, 10:00–11:00<br>Room Orion, 3rd floor</div>""")),
    "chat_group_plan": (430, 860, 2, f"""{BASE}<div style="background:#efeae2;height:100vh;padding:12px;font-size:15px">
        <div style="background:#075e54;color:#fff;margin:-12px -12px 12px;padding:12px"><b>Friday crew</b><br><span style="font-size:12px;opacity:.8">Tom, Ana, Petr, You</span></div>
        <div style="text-align:center;font-size:12px;color:#667">TODAY</div>
        {''.join(f'<div style="background:#fff;border-radius:8px;padding:6px 10px;margin:8px 60px 0 0"><b style="color:{c}">{n}</b><br>{t}<div style="text-align:right;font-size:11px;color:#999">{h}</div></div>' for n,c,t,h in [
            ("Tom","#e11d48","drinks this week?","12:02"),("Ana","#2563eb","thu?","12:05"),("Petr","#16a34a","can't do thu, fri works","12:11"),
            ("Ana","#2563eb","fri 8pm at Vzorkovna?","12:14"),("Tom","#e11d48","👍","12:20"),("Petr","#16a34a","👍 see you there","12:31")])}</div>"""),
    "ticket_chosen_show": (1000, 640, 1, f"""{BASE}<div style="margin:30px;border:1px solid #e5e7eb;border-radius:14px;overflow:hidden">
        <div style="background:#7f1d1d;color:#fff;padding:22px 28px"><div class="small" style="color:#fecaca">NÁRODNÍ DIVADLO · E-TICKET</div><div style="font-size:30px;font-weight:700">Hamlet</div>
        <div>Performances: Fri 23 Oct · Sat 24 Oct · Sun 25 Oct, always 19:30</div></div>
        <div style="padding:22px 28px;font-size:18px"><div class="small">YOUR TICKET</div><b>Saturday 24 October 2026, 19:30</b><br>Row 7 · Seat 12 · Balcony<br>
        <span class="small">Doors open 45 minutes before. Running time approx. 3 h incl. interval.</span></div></div>"""),
    "email_cancelled_then_new": (1000, 640, 1, mail(
        "Workshop date change", "Training Team", "training@northwind-example.cz", "#be123c", "Mon, 12 Oct, 09:40",
        """<p>Hello,</p><p>Unfortunately the <b>Tuesday 20 October</b> workshop is cancelled because the trainer is ill.</p>
        <p>We'll run it on <b>Thursday 22 October, 10:00–13:00</b> instead, same room (B2). No need to re-register.</p><p>Sorry for the hassle!</p>""")),
    "email_forward_last_year": (1000, 820, 1, mail(
        "Fwd: Thank you for attending CityTech Summit", "Jiří Novotný", "jiri@northwind-example.cz", "#0d9488", "Mon, 12 Oct, 11:55",
        """<p>FYI, this year's dates are out: <b>Wed 4 – Thu 5 November 2026</b>, same venue. Want to go together?</p>
        <div style="border-left:3px solid #e5e7eb;padding-left:12px;color:#6b7280;margin-top:18px">---------- Forwarded message ----------<br>
        From: CityTech Summit &lt;hello@citytech-example.eu&gt;<br>Date: 7 Nov 2025<br><br>
        Thank you for attending CityTech Summit 2025 on 5–6 November 2025 at Forum Karlín! Slides and recordings are now online.</div>""")),
    "chat_time_correction": (420, 700, 2, f"""{BASE}<div style="background:#f2f2f7;height:100vh;padding:14px">
        <div style="text-align:center;font-size:13px;color:#8e8e93">Kuba<br>iMessage · Today 15:02</div>
        <div style="margin-top:18px;background:#e5e5ea;border-radius:18px;padding:10px 14px;max-width:80%">dinner today at 6?</div>
        <div style="margin-top:8px;background:#e5e5ea;border-radius:18px;padding:10px 14px;max-width:80%">wait no, make it 7 — I have gym till 6:30</div>
        <div style="margin:10px 0 0 auto;background:#0b84fe;color:#fff;border-radius:18px;padding:10px 14px;max-width:60%">ok! where?</div>
        <div style="margin-top:8px;background:#e5e5ea;border-radius:18px;padding:10px 14px;max-width:80%">Lokál at 7 then 🍻</div></div>"""),
    "poster_past_year": (700, 900, 1, """<div style="height:100vh;background:#1e1b4b;color:#e0e7ff;font-family:'Arial Black',sans-serif;padding:50px">
        <div style="font-size:24px;letter-spacing:.25em">ROXY PRAGUE PRESENTS</div>
        <div style="font-size:96px;line-height:1;margin-top:60px;color:#f0abfc">NEON<br>NIGHTS</div>
        <div style="font-size:52px;margin-top:70px;color:#fde047">SAT 15.11.2025</div>
        <div style="font:600 28px Arial;margin-top:16px">20:00 · Dlouhá 33</div></div>"""),
    "web_course_recurring": (1100, 700, 1, f"""{BASE}<div style="padding:36px 56px;max-width:960px"><div class="small">KERAMICKÁ DÍLNA · COURSES</div>
        <h1 style="font-size:34px">Pottery for beginners</h1>
        <div class="box" style="font-size:18px"><b>Thursdays, 19:00–21:00</b><br>6 sessions, starting 29 October 2026<br>Studio Hlína, Křižíkova 18, Praha 8</div>
        <p>Learn to center clay, throw cylinders and glaze your first bowls. All materials and two firings included.</p>
        <span class="btn">Book a place · 4 900 Kč</span></div>"""),
    "email_no_event": (1000, 600, 1, mail(
        "Your password was changed", "Northwind Accounts", "security@northwind-example.cz", "#475569", "Mon, 12 Oct, 13:20",
        """<p>The password for your Northwind account was changed on 12 October 2026 at 13:18.</p>
        <p>If this was you, no action is needed. If not, reset your password right away.</p><span class="btn">Review activity</span>""")),
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, (width, height, scale, html) in CASES.items():
            if len(sys.argv) > 1 and name not in sys.argv[1:]:
                continue
            page = Path(tmp) / f"{name}.html"
            page.write_text("<!doctype html><meta charset=utf-8>" + html)
            subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", f"--user-data-dir={tmp}/profile",
                            f"--window-size={width},{height}", f"--force-device-scale-factor={scale}",
                            f"--screenshot={OUT / (name + '.png')}", page.as_uri()],
                           check=True, capture_output=True, timeout=60)
            print("rendered", name)


if __name__ == "__main__":
    main()
