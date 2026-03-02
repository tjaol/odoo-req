# 📖 คู่มือภาษาไทย — ssh_key_inject.sh

เครื่องมืออัตโนมัติสำหรับจัดการเซิร์ฟเวอร์ Odoo 19 ผ่าน SSH

## 🎯 แนวคิดหลัก (Inject → Execute → Revoke)

สคริปต์นี้ใช้หลักการ **"ใช้แล้วถอน"**:

1. **Inject** — ฝัง SSH public key ไปยังเซิร์ฟเวอร์เป้าหมาย
2. **Execute** — ทำงานที่ต้องการ (ติดตั้ง dependency, ตั้ง logrotate ฯลฯ)
3. **Revoke** — ถอน key ออกทันทีหลังทำเสร็จ

วิธีนี้ช่วยให้:
- ✅ ไม่ทิ้ง key ค้างบนเซิร์ฟเวอร์ → ลดความเสี่ยงด้านความปลอดภัย
- ✅ ไม่ต้องตั้ง key ถาวร → ใช้ครั้งเดียวจบ
- ✅ ถ้าเซิร์ฟเวอร์มี key อยู่แล้ว → ใช้ `--no-inject` ข้ามขั้นตอน inject/revoke ได้

## 📋 พารามิเตอร์หลัก

| ตัวเลือก | ค่าเริ่มต้น | คำอธิบาย |
|---|---|---|
| `--host` | (บังคับ) | IP ของเซิร์ฟเวอร์เป้าหมาย |
| `--port` | 22 | พอร์ต SSH |
| `--user` | root | ชื่อผู้ใช้ SSH |
| `--password` | — | รหัสผ่าน SSH (สำหรับ password mode) |
| `--key` | — | พาธของ private key |
| `--pubkey-file` | — | พาธของ public key (ถ้าไม่ระบุจะหาอัตโนมัติ) |
| `--auth-mode` | auto | โหมดยืนยันตัวตน: `auto` / `password` / `key` |
| `--no-inject` | ปิด | ข้าม inject/revoke (ใช้ key ที่มีอยู่แล้ว) |
| `--action` | (บังคับ) | คำสั่งที่ต้องการทำ (ดูตารางด้านล่าง) |
| `--rotate-days` | 30 | จำนวนวันที่เก็บ log |
| `--rotate-size` | — | หมุน log เมื่อขนาดเกินค่านี้ (เช่น `100M`) |
| `--rotate-count` | ไม่จำกัด | จำนวนไฟล์ backup สูงสุด |
| `--run-cmd` | — | คำสั่ง remote (เฉพาะ action `auto`) |

### Action ที่รองรับ

| Action | คำอธิบาย |
|---|---|
| `inject` | ฝัง public key ไปยัง authorized_keys |
| `revoke` | ถอน public key ออก |
| `status` | ตรวจสอบว่า key มีอยู่หรือไม่ |
| `auto` | inject → รัน `--run-cmd` → revoke (ครบวงจร) |
| `odoo-check` | ตรวจสอบ + ติดตั้ง dependency ของ Odoo 19 ที่ขาด |
| `odoo-setup` | odoo-check + remote-logrotate (ทำครบทุกอย่าง) |
| `remote-logrotate` | ตั้งค่า logrotate บนเซิร์ฟเวอร์ remote |
| `logrotate` | หมุน log ของ OpenClaw ในเครื่อง local |

---

## 📝 ตัวอย่างการใช้งาน

### ตัวอย่างที่ 1: `remote-logrotate` — ตั้งค่าหมุน log อัตโนมัติ

**สิ่งที่ทำ:** เข้าเซิร์ฟเวอร์ Odoo ผ่าน SSH → ค้นหาพาธ log ของ Odoo อัตโนมัติ → เขียนไฟล์ logrotate ลง `/etc/logrotate.d/odoo` → เก็บ log ย้อนหลัง 30 วัน ป้องกันดิสก์เต็ม

```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode key --no-inject \
  --key ~/.ssh/id_ed25519 \
  --action remote-logrotate \
  --rotate-days 30
```

**ขั้นตอนภายใน (3 ขั้นตอน):**

| ขั้นตอน | สิ่งที่เกิดขึ้น |
|---|---|
| 1. Inject | ฝัง SSH key (ข้ามเพราะใช้ `--no-inject`) |
| 2. Execute | SSH เข้าเซิร์ฟเวอร์ → ค้นหาไฟล์ log ของ Odoo → สร้าง logrotate config → ใช้ `copytruncate` เพื่อไม่ต้อง restart Odoo |
| 3. Revoke | ถอน key (ข้ามเพราะใช้ `--no-inject`) |

> 💡 **สรุป:** ตั้งค่าหมุน log อัตโนมัติบนเซิร์ฟเวอร์ เก็บ 30 วัน ป้องกันดิสก์เต็ม โดยไม่ต้อง restart Odoo

---

### ตัวอย่างที่ 2: `odoo-check` — ตรวจสอบ dependency ที่ขาด

**สิ่งที่ทำ:** เข้าเซิร์ฟเวอร์ → ดาวน์โหลด `requirements.txt` ของ Odoo 19 → ตรวจสอบ Python package + C library ที่ขาด → ติดตั้งอัตโนมัติ (ถ้ามี sudo)

```bash
./ssh_key_inject.sh \
  --host 10.0.0.1 --port 14321 --user adminfpd \
  --auth-mode key --no-inject \
  --key ~/.ssh/id_ed25519 \
  --action odoo-check
```

**ขั้นตอนภายใน (3 ขั้นตอน):**

| ขั้นตอน | สิ่งที่เกิดขึ้น |
|---|---|
| 1. Inject | ฝัง SSH key (ข้ามเพราะใช้ `--no-inject`) |
| 2. Execute | SSH เข้าเซิร์ฟเวอร์ → ตรวจ system packages (libpq-dev, libxml2-dev ฯลฯ) → ตรวจ Python packages (จาก requirements.txt) → ติดตั้งตัวที่ขาดอัตโนมัติ |
| 3. Revoke | ถอน key (ข้ามเพราะใช้ `--no-inject`) |

> 💡 **สรุป:** สแกน dependency ทั้งหมดของ Odoo 19 บนเซิร์ฟเวอร์ ตัวไหนขาดก็ติดตั้งให้เลย ไม่ต้องนั่งเช็คเอง

---

## ⚠️ หมายเหตุ

- การตั้ง logrotate ต้องใช้ `sudo` บนเซิร์ฟเวอร์ (เพื่อเขียน `/etc/logrotate.d/odoo`)
- ถ้าไม่มี sudo สคริปต์จะ fallback ไปตัด log ตรงๆ แทน
- ใช้ `copytruncate` จึงไม่ต้อง restart Odoo หลังหมุน log
- ต้องติดตั้ง `sshpass` หากใช้ password auth: `brew install hudochenkov/sshpass/sshpass`
