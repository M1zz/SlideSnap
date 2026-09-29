"""스크린샷용 데모 장표 내용 (언어별). make_demo_photos.py 가 읽는다.

발표(deck)마다 제목과 장표 목록. 장표 종류:
  title   : 큰 제목 + 부제
  bullets : 제목 + 글머리 목록
  bars    : 제목 + 막대그래프 (label, 값)
  steps   : 제목 + 단계 흐름
  quote   : 인용문 + 출처
"""

DECKS = {
    "ko": [
        {"title": "UX 리서치 방법론", "date": "2026:09:24 14:0{i}:00", "accent": "#3b6cf6", "slides": [
            {"kind": "title", "title": "UX 리서치 방법론", "sub": "사용자를 이해하는 다섯 가지 방법"},
            {"kind": "bullets", "title": "사용자 인터뷰 준비", "items": ["목표를 한 문장으로 정리한다", "열린 질문으로 시작한다", "행동을 묻고, 의견은 나중에", "녹음 동의를 먼저 받는다"]},
            {"kind": "steps", "title": "리서치 진행 순서", "items": ["질문 설계", "참가자 모집", "사용자 인터뷰", "인사이트 정리"]},
            {"kind": "bars", "title": "방법별 활용 빈도", "items": [["사용자 인터뷰", 82], ["설문조사", 64], ["사용성 테스트", 57], ["다이어리 연구", 23]]},
            {"kind": "quote", "quote": "사용자가 말하는 것보다\n사용자가 하는 것을 보라", "by": "제이콥 닐슨"},
            {"kind": "bullets", "title": "인사이트 정리하기", "items": ["어피니티 다이어그램으로 묶기", "반복되는 불편을 우선순위로", "사용자 인터뷰 원문을 근거로 남기기"]},
        ]},
        {"title": "마케팅 전략 세미나", "date": "2026:09:18 10:1{i}:00", "accent": "#e8573f", "slides": [
            {"kind": "title", "title": "2026 마케팅 전략", "sub": "성장 채널 다시 보기"},
            {"kind": "bars", "title": "채널별 전환율", "items": [["검색 광고", 4.8], ["SNS", 3.1], ["이메일", 6.2], ["제휴", 2.4]]},
            {"kind": "steps", "title": "고객 여정", "items": ["인지", "관심", "구매", "재구매"]},
            {"kind": "bullets", "title": "하반기 실행 과제", "items": ["리텐션 캠페인 개편", "사용자 인터뷰 기반 메시지 테스트", "제휴 채널 확대"]},
        ]},
        {"title": "데이터 분석 입문", "date": "2026:09:11 19:3{i}:00", "accent": "#16a37a", "slides": [
            {"kind": "title", "title": "데이터 분석 입문", "sub": "3주차 · 데이터 시각화"},
            {"kind": "bullets", "title": "좋은 차트의 조건", "items": ["한 차트에 한 메시지", "축과 단위를 분명하게", "색은 강조할 때만"]},
            {"kind": "bars", "title": "월별 방문자 (천 명)", "items": [["6월", 42], ["7월", 55], ["8월", 61], ["9월", 78]]},
            {"kind": "steps", "title": "분석 흐름", "items": ["수집", "정제", "탐색", "시각화"]},
            {"kind": "quote", "quote": "데이터는 새로운 석유다", "by": "클라이브 험비"},
        ]},
        {"title": "경영학원론 3주차", "date": "2026:09:04 13:0{i}:00", "accent": "#8a4fd8", "slides": [
            {"kind": "title", "title": "경영학원론", "sub": "3주차 · 조직과 리더십"},
            {"kind": "bullets", "title": "리더십의 세 가지 유형", "items": ["지시형 리더십", "코칭형 리더십", "위임형 리더십"]},
            {"kind": "steps", "title": "의사결정 과정", "items": ["문제 정의", "대안 탐색", "평가", "실행"]},
            {"kind": "bars", "title": "직무 만족 요인", "items": [["성장 기회", 71], ["보상", 66], ["동료", 58], ["자율성", 52]]},
        ]},
    ],
    "en": [
        {"title": "UX Research Methods", "date": "2026:09:24 14:0{i}:00", "accent": "#3b6cf6", "slides": [
            {"kind": "title", "title": "UX Research Methods", "sub": "Five ways to understand your users"},
            {"kind": "bullets", "title": "Preparing a User Interview", "items": ["Write the goal in one sentence", "Start with open questions", "Ask about behavior, then opinions", "Get consent to record first"]},
            {"kind": "steps", "title": "Research Process", "items": ["Plan", "Recruit", "User Interview", "Synthesize"]},
            {"kind": "bars", "title": "How Often Teams Use Each Method", "items": [["User interview", 82], ["Survey", 64], ["Usability test", 57], ["Diary study", 23]]},
            {"kind": "quote", "quote": "Pay attention to what users do,\nnot what they say.", "by": "Jakob Nielsen"},
            {"kind": "bullets", "title": "Synthesizing Insights", "items": ["Group notes with an affinity map", "Prioritize recurring pain points", "Keep user interview quotes as evidence"]},
        ]},
        {"title": "Marketing Strategy Seminar", "date": "2026:09:18 10:1{i}:00", "accent": "#e8573f", "slides": [
            {"kind": "title", "title": "2026 Marketing Strategy", "sub": "Rethinking our growth channels"},
            {"kind": "bars", "title": "Conversion Rate by Channel", "items": [["Search ads", 4.8], ["Social", 3.1], ["Email", 6.2], ["Partners", 2.4]]},
            {"kind": "steps", "title": "Customer Journey", "items": ["Awareness", "Interest", "Purchase", "Loyalty"]},
            {"kind": "bullets", "title": "H2 Priorities", "items": ["Revamp retention campaigns", "Test messaging from user interview findings", "Expand partner channels"]},
        ]},
        {"title": "Intro to Data Analysis", "date": "2026:09:11 19:3{i}:00", "accent": "#16a37a", "slides": [
            {"kind": "title", "title": "Intro to Data Analysis", "sub": "Week 3 · Data Visualization"},
            {"kind": "bullets", "title": "What Makes a Good Chart", "items": ["One message per chart", "Clear axes and units", "Use color only for emphasis"]},
            {"kind": "bars", "title": "Monthly Visitors (thousands)", "items": [["Jun", 42], ["Jul", 55], ["Aug", 61], ["Sep", 78]]},
            {"kind": "steps", "title": "Analysis Workflow", "items": ["Collect", "Clean", "Explore", "Visualize"]},
            {"kind": "quote", "quote": "Data is the new oil.", "by": "Clive Humby"},
        ]},
        {"title": "Management 101 · Week 3", "date": "2026:09:04 13:0{i}:00", "accent": "#8a4fd8", "slides": [
            {"kind": "title", "title": "Principles of Management", "sub": "Week 3 · Organizations & Leadership"},
            {"kind": "bullets", "title": "Three Leadership Styles", "items": ["Directive leadership", "Coaching leadership", "Delegating leadership"]},
            {"kind": "steps", "title": "Decision-Making Process", "items": ["Define", "Explore", "Evaluate", "Act"]},
            {"kind": "bars", "title": "Drivers of Job Satisfaction", "items": [["Growth", 71], ["Pay", 66], ["Peers", 58], ["Autonomy", 52]]},
        ]},
    ],
}

# 스크린샷 문구 · 검색어 (언어별)
SEARCH = {"ko": "사용자 인터뷰", "en": "user interview"}
