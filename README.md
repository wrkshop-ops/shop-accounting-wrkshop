# ระบบบันทึกสินค้า รายรับรายจ่าย ร้านค้า

โปรเจกต์นี้เตรียมเชื่อม Supabase project `shop-accounting-wrkshop` และ GitHub repository `wrkshop-ops/shop-accounting-wrkshop` โดยยังคง Google Apps Script และ Google Sheet เดิมไว้เป็นระบบสำรอง

## พัฒนาใน VS Code

1. คัดลอก `.env.example` เป็น `.env` แล้วใส่ Supabase publishable key ของโปรเจกต์นี้
2. ติดตั้งแพ็กเกจด้วย `npm install`
3. ตรวจ syntax ด้วย `npm run check`

ห้ามใส่ secret key หรือ service role key ในไฟล์ฝั่ง browser และห้าม commit `.env`

Migration ใน `supabase/migrations/0001_initial.sql` ยังไม่ได้ย้ายข้อมูลจาก Google Sheet และควรตรวจสอบ schema ก่อนนำไปใช้กับฐานข้อมูลจริง
