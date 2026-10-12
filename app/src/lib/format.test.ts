// اختبارات التنسيق: NUM-001 وB060–B062 وDATE-001 وQTY-004 (حالة القبول D29 لجزء العرض)
import { describe, it, expect } from 'vitest';
import { fmtAmount, fmtPct, fmtQty, fmtInt, fmtDate, fmtMonth, sum, roundTo, parseDateInput } from './format';

describe('NUM-001', () => {
  it('الإجمالي من الأصل ثم التقريب: 1.2344 + 1.2344 = 2.469', () => {
    expect(fmtAmount(sum(['1.2344', '1.2344']))).toBe('2.469');
    expect(fmtAmount('1.2344')).toBe('1.234');
  });
  it('0.4 + 0.4 يعرض مجموعًا 1 لا صفرًا', () => {
    expect(fmtInt(sum(['0.4', '0.4']))).toBe('1');
  });
  it('المبالغ ثلاث منازل والنسب حتى منزلتين دون أصفار زائدة', () => {
    expect(fmtAmount('11518.933')).toBe('11518.933');
    expect(fmtAmount('16')).toBe('16.000');
    expect(fmtAmount('28.50100000000000000000')).toBe('28.501');
    expect(fmtPct('2.50')).toBe('2.5');
    expect(fmtPct('12.345')).toBe('12.35');
    expect(fmtPct('100')).toBe('100');
  });
  it('تعادل النصف بعيدًا عن الصفر بلا أخطاء فاصلة عائمة', () => {
    expect(roundTo('1.0005', 3)).toBe('1.001');
    expect(roundTo('-1.0005', 3)).toBe('-1.001');
    expect(roundTo(1.005, 2)).toBe('1.01');
    expect(roundTo('-0.0004', 3)).toBe('0.000');
  });
  it('D29: الكمية 5.5 كما هي في التفاصيل، وعدد صحيح في البطاقة', () => {
    expect(fmtQty('5.5')).toBe('5.5');
    expect(fmtQty('5.50')).toBe('5.5');
    expect(fmtQty('12')).toBe('12');
    expect(fmtInt('5.5')).toBe('6');
  });
});

describe('DATE-001', () => {
  it('التاريخ D/M/YYYY والشهر M/YYYY', () => {
    expect(fmtDate('2026-12-01')).toBe('1/12/2026');
    expect(fmtMonth('2026-12-01')).toBe('12/2026');
  });
  it('قراءة صيغ المصدر DD/MM/YYYY دون عكس اليوم والشهر', () => {
    expect(parseDateInput('03/01/2026')).toBe('2026-01-03');
    expect(parseDateInput('3/1/2026')).toBe('2026-01-03');
    expect(parseDateInput('2026-01-03')).toBe('2026-01-03');
    expect(parseDateInput('31/02/2026')).toBeNull();
    expect(parseDateInput('abc')).toBeNull();
  });
});
