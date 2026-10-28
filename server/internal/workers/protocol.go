package workers

import (
	"fmt"
	"math"
	"strings"
	"time"

	"pocketledger/server/internal/ledger"
	"pocketledger/server/internal/strictjson"
)

type Summary struct {
	SpentCents          int64  `json:"spent_cents"`
	RemainingCents      int64  `json:"remaining_cents"`
	ElapsedDays         int    `json:"elapsed_days"`
	DaysInMonth         int    `json:"days_in_month"`
	DaysRemaining       int    `json:"days_remaining"`
	ProjectedCents      int64  `json:"projected_cents"`
	DailyAllowanceCents int64  `json:"daily_allowance_cents"`
	Status              string `json:"status"`
}

type Category struct {
	Category   string `json:"category"`
	SpentCents int64  `json:"spent_cents"`
	Count      int    `json:"count"`
}

type Daily struct {
	Date       string `json:"date"`
	SpentCents int64  `json:"spent_cents"`
}

type Analytics struct {
	Categories []Category           `json:"categories"`
	Daily      []Daily              `json:"daily"`
	Largest    []ledger.Transaction `json:"largest"`
}

func sum(total, value int64) (int64, error) {
	if value < 0 || total > math.MaxInt64-value {
		return 0, fmt.Errorf("invalid or overflowing worker totals")
	}
	return total + value, nil
}

// Validate worker output before forwarding it. These are consistency checks,
// never a fallback implementation that supplies missing calculations.
func decodeOutputs(input Input, summaryJSON, analyticsJSON []byte) (Summary, Analytics, error) {
	var summary Summary
	var analytics Analytics
	if err := strictjson.Object(summaryJSON, &summary, "spent_cents", "remaining_cents", "elapsed_days", "days_in_month", "days_remaining", "projected_cents", "daily_allowance_cents", "status"); err != nil {
		return summary, analytics, fmt.Errorf("invalid Haskell output: %w", err)
	}
	if err := strictjson.Object(analyticsJSON, &analytics, "categories", "daily", "largest"); err != nil {
		return summary, analytics, fmt.Errorf("invalid Scala output: %w", err)
	}
	day, err := ledger.ParseDate(input.AsOf)
	if err != nil {
		return summary, analytics, err
	}
	days := time.Date(day.Year(), day.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
	var expectedSpent int64
	eligible := make(map[string]ledger.Transaction)
	for _, item := range input.Transactions {
		if strings.HasPrefix(item.Date, input.Month+"-") && item.Date <= input.AsOf {
			expectedSpent, err = sum(expectedSpent, item.AmountCents)
			if err != nil {
				return summary, analytics, err
			}
			eligible[item.ID] = item
		}
	}
	status := "under_budget"
	if expectedSpent == input.MonthlyLimitCents {
		status = "at_budget"
	} else if expectedSpent > input.MonthlyLimitCents {
		status = "over_budget"
	}
	if summary.SpentCents != expectedSpent || summary.RemainingCents != input.MonthlyLimitCents-expectedSpent || summary.ElapsedDays != day.Day() || summary.DaysInMonth != days || summary.DaysRemaining != days-day.Day() || summary.ProjectedCents < expectedSpent || summary.DailyAllowanceCents < 0 || summary.Status != status {
		return summary, analytics, fmt.Errorf("Haskell output is inconsistent with the reporting snapshot")
	}
	if analytics.Categories == nil || analytics.Daily == nil || analytics.Largest == nil {
		return summary, analytics, fmt.Errorf("Scala arrays must be present, not null")
	}
	var categorySpent, dailySpent int64
	categoryCount := 0
	seen := make(map[string]bool)
	for i, row := range analytics.Categories {
		if !ledger.ValidCategory(row.Category) || seen[row.Category] || row.Count < 1 || row.SpentCents < 1 {
			return summary, analytics, fmt.Errorf("invalid Scala category")
		}
		seen[row.Category] = true
		if i > 0 {
			prev := analytics.Categories[i-1]
			if prev.SpentCents < row.SpentCents || (prev.SpentCents == row.SpentCents && prev.Category > row.Category) {
				return summary, analytics, fmt.Errorf("Scala categories are not deterministically sorted")
			}
		}
		categorySpent, err = sum(categorySpent, row.SpentCents)
		if err != nil {
			return summary, analytics, err
		}
		if row.Count > len(eligible)-categoryCount {
			return summary, analytics, fmt.Errorf("Scala category counts exceed snapshot")
		}
		categoryCount += row.Count
	}
	if len(analytics.Daily) != day.Day() {
		return summary, analytics, fmt.Errorf("Scala daily series must include every completed reporting day")
	}
	for i, row := range analytics.Daily {
		if row.Date != fmt.Sprintf("%s-%02d", input.Month, i+1) {
			return summary, analytics, fmt.Errorf("invalid Scala daily date")
		}
		dailySpent, err = sum(dailySpent, row.SpentCents)
		if err != nil {
			return summary, analytics, err
		}
	}
	if categorySpent != expectedSpent || dailySpent != expectedSpent || categoryCount != len(eligible) {
		return summary, analytics, fmt.Errorf("Scala totals disagree with the ledger snapshot")
	}
	maximum := min(5, len(eligible))
	if len(analytics.Largest) != maximum {
		return summary, analytics, fmt.Errorf("invalid Scala largest-expense count")
	}
	seenIDs := make(map[string]bool)
	for i, item := range analytics.Largest {
		original, ok := eligible[item.ID]
		if !ok || seenIDs[item.ID] || original != item {
			return summary, analytics, fmt.Errorf("Scala returned an unknown or modified expense")
		}
		seenIDs[item.ID] = true
		if i > 0 {
			prev := analytics.Largest[i-1]
			if prev.AmountCents < item.AmountCents || (prev.AmountCents == item.AmountCents && (prev.Date > item.Date || (prev.Date == item.Date && prev.ID > item.ID))) {
				return summary, analytics, fmt.Errorf("Scala largest expenses are not deterministically sorted")
			}
		}
	}
	return summary, analytics, nil
}
