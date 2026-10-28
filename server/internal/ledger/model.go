package ledger

import (
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const MaxCents int64 = 100000000
const DefaultBudget int64 = 200000

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var categories = map[string]bool{"food": true, "transport": true, "housing": true, "shopping": true, "health": true, "entertainment": true, "other": true}

type Transaction struct {
	ID          string `json:"id"`
	AmountCents int64  `json:"amount_cents"`
	Category    string `json:"category"`
	Note        string `json:"note"`
	Date        string `json:"date"`
}

type Budget struct {
	MonthlyLimitCents int64  `json:"monthly_limit_cents"`
	Currency          string `json:"currency"`
}

func NormalizeID(id string) (string, error) {
	if !uuidPattern.MatchString(id) {
		return "", fmt.Errorf("id must be a UUID in 8-4-4-4-12 hexadecimal form")
	}
	return strings.ToLower(id), nil
}

func ValidCategory(category string) bool { return categories[category] }

func ValidateCents(cents int64) error {
	if cents < 1 || cents > MaxCents {
		return fmt.Errorf("money must be integer USD cents between 1 and %d", MaxCents)
	}
	return nil
}

func ParseDate(value string) (time.Time, error) {
	day, err := time.Parse("2006-01-02", value)
	if err != nil || len(value) != 10 || day.Year() < 2000 || day.Year() > 2100 {
		return time.Time{}, fmt.Errorf("date must be a valid YYYY-MM-DD in years 2000 through 2100")
	}
	return day, nil
}

func (t *Transaction) Validate() error {
	id, err := NormalizeID(t.ID)
	if err != nil {
		return err
	}
	if err := ValidateCents(t.AmountCents); err != nil {
		return err
	}
	if !ValidCategory(t.Category) {
		return fmt.Errorf("category must be food, transport, housing, shopping, health, entertainment, or other")
	}
	if !utf8.ValidString(t.Note) || utf8.RuneCountInString(t.Note) > 140 {
		return fmt.Errorf("note must contain at most 140 Unicode code points")
	}
	if _, err := ParseDate(t.Date); err != nil {
		return err
	}
	t.ID = id
	return nil
}
