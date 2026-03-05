# คู่มือการใช้งาน ssh_key_inject.sh

ไฟล์นี้เป็นเครื่องมือแนวคิด **“Inject key → ทำงานอัตโนมัติ → Revoke key”**
จุดเด่นคือช่วยลดปัญหาการใส่รหัสผ่านซ้ำ ๆ และลดโอกาสที่งานจะค้างตอนพิมพ์ sudo โดยเฉพาะในงานติดตั้ง dependency หรือจัดการ logrotate บนเครื่องปลายทางแบบอัตโนมัติ

## แนวคิดของคำสั่ง

1. ใช้การ inject SSH public key ชั่วคราว เข้าไปใน `~/.ssh/authorized_keys` ของเครื่องปลายทาง
2. รันงานที่ต้องทำ (เช่น เช็ก/ติดตั้ง Odoo dependencies หรือจัดการ logrotate)
3. ลบ key ออกเมื่อจบงาน (revoke) เพื่อความปลอดภัย
4. ถ้าเครื่องปลายทางมี key ของเราอยู่แล้ว สามารถใช้ `--no-inject` เพื่อข้ามขั้นตอนการเพิ่ม/ลบ key ได้

## พารามิเตอร์หลัก

- `--host <ip>`: IP หรือ hostname ของเครื่องปลายทาง
- `--port <port>`: พอร์ต SSH (ค่าเริ่มต้น 22)
- `--user <user>`: ผู้ใช้ SSH
- `--password <pass>`: รหัสผ่าน SSH/sudo (ใช้ในขั้น inject/revoke และงานที่ต้อง sudo)
- `--key <path>`: path ของ private key สำหรับเชื่อมต่อแบบ key-based
- `--pubkey-file <path>`: path ของ public key สำหรับนำไปฝังที่ปลายทาง
- `--auth-mode <auto|password|key>`: โหมดการยืนยันตัวตน
- `--no-inject`: ข้ามขั้น inject/revoke (ใช้เมื่อ server เชื่อถือ key อยู่แล้ว)
- `--action <...>`: โหมดการทำงาน
  - `inject`: เพิ่ม public key
  - `revoke`: ลบ public key ที่เคย inject
  - `status`: ตรวจสอบสถานะการเชื่อมต่อ/คีย์
  - `auto`: inject → run command → revoke
  - `odoo-check`: ตรวจ dependency ของ Odoo และติดตั้งส่วนที่ขาด
  - `odoo-setup`: ทำ flow setup Odoo ครบชุด
  - `remote-logrotate`: ตั้งค่า logrotate บนเครื่องปลายทาง
  - `logrotate`: จัดการ logrotate ฝั่ง local
- `--run-cmd "<cmd>"`: คำสั่งที่จะให้รันตอนใช้ action auto
- `--rotate-days <n>` / `--rotate-size <size>` / `--rotate-count <n>`: พารามิเตอร์ควบคุม logrotate

---

## ตัวอย่างการใช้งาน (Examples)

### ตัวอย่างที่ 1: ตั้งค่า Logrotate บนเครื่องปลายทาง
```bash
./ssh_key_inject.sh \
  --host 203.150.106.131 \
  --port 14321 \
  --user admincu01 \
  --password '$KeywCsRVLKb1' \
  --key ~/.ssh/id_ed25519 \
  --pubkey-file ~/.ssh/id_ed25519.pub \
  --action remote-logrotate \
  --rotate-days 30
```
**คำสั่งนี้หมายถึงอะไร:**
ระบบจะทำการเชื่อมต่อเข้าไปยังเครื่อง `203.150.106.131` ผ่านพอร์ต `14321` ด้วยผู้ใช้ `admincu01` โดยใช้รหัสผ่านเพื่อฝัง Public Key ก่อน จากนั้นจะรันโหมด `remote-logrotate` เพื่อตั้งค่าการจัดการ Log บนเซิร์ฟเวอร์ปลายทาง โดยกำหนดให้เก็บ Log ย้อนหลังเป็นเวลา 30 วัน (`--rotate-days 30`) เมื่อทำงานเสร็จ ระบบจะลบ Public Key ออกจากเป้าหมายโดยอัตโนมัติเพื่อความปลอดภัย

### ตัวอย่างที่ 2: ตรวจสอบและติดตั้ง Odoo Dependencies
```bash
./ssh_key_inject.sh \
  --host 203.150.106.131 \
  --port 14321 \
  --user admincu01 \
  --password '$KeywCsRVLKb1' \
  --key ~/.ssh/id_ed25519 \
  --pubkey-file ~/.ssh/id_ed25519.pub \
  --action odoo-check
```
**คำสั่งนี้หมายถึงอะไร:**
เช่นเดียวกับตัวอย่างแรก ระบบจะเจาะเข้าไปฝัง Key ให้ก่อน แต่ในครั้งนี้จะรันโหมด `odoo-check` ซึ่งสคริปต์จะทำการตรวจสอบหา Dependencies หรือ Packages พื้นฐานที่ Odoo จำเป็นต้องใช้บนเครื่อง `203.150.106.131` หากตัวไหนขาดหายไป สคริปต์จะใช้สิทธิ์ Sudo (โดยใช้พาสเวิร์ดที่ให้มา) ติดตั้งให้จนครบ เมื่อจัดการครบถ้วนแล้วก็จะลบ Key ออกเช่นเดิม
