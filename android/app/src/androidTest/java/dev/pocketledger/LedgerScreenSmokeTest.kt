package dev.pocketledger

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LedgerScreenSmokeTest {
    @get:Rule val compose = createComposeRule()
    @Test fun offlineEmptyStateOpensExpenseFormAndDispatchesExactUserInput() {
        var capturedAmount: String? = null
        var capturedNote: String? = null
        compose.setContent {
            PocketLedgerTheme {
                LedgerScreen(LedgerUiState(loading = false), {}, {}, { amount, _, note, _, saved -> capturedAmount = amount; capturedNote = note; saved() }, {}, { _, _, saved -> saved() }, {})
            }
        }
        compose.onNodeWithTag("addExpense").performClick()
        compose.onNodeWithTag("amountInput").performTextInput("12.50")
        compose.onNodeWithTag("noteInput").performTextInput("Synthetic lunch")
        compose.onNodeWithTag("saveExpense").performClick()
        compose.runOnIdle { assertEquals("12.50", capturedAmount); assertEquals("Synthetic lunch", capturedNote) }
        compose.onNodeWithTag("settings").performClick()
        compose.onNodeWithTag("endpointInput").assertTextContains("http://10.0.2.2:8080")
    }
}
