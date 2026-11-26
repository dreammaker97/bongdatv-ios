# BongDaTV iOS (`BongDaTV.ipa`)

Ứng dụng iOS native (SwiftUI + AVKit + Local On-Device HLS Relay) để xem bóng đá trực tiếp và lịch thi đấu Ngoại hạng Anh & Cúp C1 từ máy chủ tự host.

## Tính năng chính

- **Phát trực tiếp không qua Proxy Server**: Tích hợp `LocalHLSProxy` ngay trên iPhone (`127.0.0.1`) để tự gắn header `Referer` và `User-Agent` chuẩn qua mọi chuyển hướng CDN, giúp luồng video đi thẳng từ CDN về iPhone mà không tốn băng thông máy chủ.
- **Tự động dự phòng thông minh**: Khi luồng trực tiếp gặp sự cố, ứng dụng tự thử lần lượt `Direct AVPlayer Header` -> `Server Proxy` -> đổi BLV dự phòng trong cùng trận.
- **Hỗ trợ iOS đầy đủ**: Picture-in-Picture (PiP), xoay ngang/dọc, luôn phát có tiếng ngay cả khi bật chế độ im lặng, bảng chọn BLV và lịch thi đấu 24h.
- **Cài đặt linh hoạt**: Mặc định kết nối địa chỉ LAN `http://192.168.1.210:8080/bongda` và cho phép cấu hình thêm Server dự phòng (tùy chọn) ngay trong phần Cài đặt để dùng khi ra ngoài 4G/5G.

## Build tự động trên GitHub Actions

Workflow `.github/workflows/build-ipa.yml` chạy XcodeGen, unit test trên iOS Simulator (`macos-15`), build ARM64 Release unsigned và đóng gói artifact `BongDaTV-IPA` (`BongDaTV.ipa`).
