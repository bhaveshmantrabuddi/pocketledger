package dev.pocketledger

import android.os.Bundle
import android.content.ClipData
import android.content.Intent
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

private val Forest = Color(0xFF1C503D)
private val Green = Color(0xFF307454)
private val Paper = Color(0xFFF5F7F4)
private val Ink = Color(0xFF182E24)
private val Muted = Color(0xFF63756B)
private val SoftGreen = Color(0xFFE4EEE5)
private val Warm = Color(0xFFB46A39)

class MainActivity: ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val ledger: LedgerViewModel = viewModel()
            val state by ledger.state.collectAsStateWithLifecycle()
            PocketLedgerTheme {
                LedgerScreen(state, ledger::sync, ledger::moveMonth, ledger::addExpense, ledger::deleteExpense, ledger::saveConfiguration, ledger::clearError, ::shareCSV)
            }
        }
    }
    private fun shareCSV(expenses: List<Expense>, month: String) {
        try {
            val folder = File(cacheDir, "exports").apply { mkdirs() }
            val file = File(folder, "PocketLedger-$month.csv")
            file.writeText(CsvExporter.export(expenses), Charsets.UTF_8)
            val uri = FileProvider.getUriForFile(this, "$packageName.exports", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri("PocketLedger CSV", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, "Export selected month"))
        } catch (_: Exception) { Toast.makeText(this, "CSV export is unavailable. Please try again.", Toast.LENGTH_LONG).show() }
    }
}

@Composable fun PocketLedgerTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = lightColorScheme(primary = Green, onPrimary = Color.White, secondary = Forest, background = Paper, surface = Color.White, onSurface = Ink, surfaceVariant = SoftGreen, error = Color(0xFFA63832)), content = content)
}

@Composable fun LedgerScreen(
    state: LedgerUiState,
    onSync: () -> Unit,
    onMonth: (Long) -> Unit,
    onAdd: (String, Category, String, String, () -> Unit) -> Unit,
    onDelete: (String) -> Unit,
    onSettings: (String, String, () -> Unit) -> Unit,
    onClearError: () -> Unit,
    onExport: (List<Expense>, String) -> Unit = { _, _ -> }
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var showAdd by rememberSaveable { mutableStateOf(false) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<Expense?>(null) }
    Surface(color = Paper, modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        Scaffold(containerColor = Paper,
            floatingActionButton = {
                ExtendedFloatingActionButton(onClick = { showAdd = true }, containerColor = Forest, contentColor = Color.White, modifier = Modifier.testTag("addExpense")) { Text("+  Add expense", fontWeight = FontWeight.SemiBold) }
            },
            topBar = {
                Column(Modifier.padding(horizontal = 22.dp, vertical = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(38.dp).clip(RoundedCornerShape(12.dp)).background(Forest), contentAlignment = Alignment.Center) { Text("P", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 23.sp) }
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) { Text("PocketLedger", fontWeight = FontWeight.Bold, fontSize = 20.sp); Text("MAKE ROOM FOR WHAT MATTERS", color = Muted, fontSize = 9.sp, letterSpacing = 1.sp) }
                        TextButton(onClick = { showSettings = true }, modifier = Modifier.testTag("settings")) { Text("Settings", fontSize = 12.sp) }
                    }
                    Spacer(Modifier.height(18.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { onMonth(-1) }, enabled = state.month.year > 2000 || state.month.monthValue > 1, modifier = Modifier.size(48.dp).semantics { contentDescription = "Previous month" }) { Text("‹", fontSize = 27.sp) }
                        Text(state.month.format(DateTimeFormatter.ofPattern("MMMM yyyy", Locale.US)), Modifier.weight(1f).testTag("monthLabel"), fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        TextButton(onClick = { onMonth(1) }, enabled = state.month.year < 2100 || state.month.monthValue < 12, modifier = Modifier.size(48.dp).semantics { contentDescription = "Next month" }) { Text("›", fontSize = 27.sp) }
                        FilledTonalButton(onClick = onSync, enabled = !state.syncing && !state.loading && !state.saving, contentPadding = PaddingValues(horizontal = 14.dp, vertical = 0.dp), modifier = Modifier.testTag("sync")) { Text(if (state.syncing) "Syncing…" else "↻  Sync", fontSize = 12.sp) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp, top = 3.dp)) {
                        Box(Modifier.size(7.dp).clip(CircleShape).background(if (state.pendingCount > 0) Warm else Green))
                        Text(if (state.pendingCount > 0) "  ${state.pendingCount} changes saved · waiting to sync" else "  On-device ledger · manual sync", color = Muted, fontSize = 11.sp)
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = tab == 0, onClick = { tab = 0 }, label = { Text("Overview") }, modifier = Modifier.testTag("overviewTab"))
                        FilterChip(selected = tab == 1, onClick = { tab = 1 }, label = { Text("Expenses") }, modifier = Modifier.testTag("expensesTab"))
                        Spacer(Modifier.weight(1f))
                        TextButton(onClick = { onExport(state.monthExpenses.map { it.expense }, state.month.toString()) }, enabled = !state.loading, modifier = Modifier.testTag("exportCsv")) { Text("Export CSV", fontSize = 11.sp) }
                    }
                }
            }
        ) { padding ->
            if (state.loading) Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(start = 22.dp, end = 22.dp, top = 4.dp, bottom = 105.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (tab == 0) {
                    item { BudgetHero(state) }
                    item {
                        Text("YOUR SPENDING, AT A GLANCE", fontSize = 11.sp, color = Muted, letterSpacing = 1.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(10.dp))
                        CategoryCard(state)
                    }
                    if (state.dashboard != null) item { ServerInsight(state.dashboard, state.pendingCount > 0) }
                    item { SectionLabel("Recent expenses", "${state.monthExpenses.size} total") }
                } else {
                    item { SectionLabel("All expenses", "${state.monthExpenses.size} this month") }
                }
                if (state.monthExpenses.isEmpty()) item { EmptyExpenses { showAdd = true } }
                val shown = if (tab == 0) state.monthExpenses.take(4) else state.monthExpenses
                items(shown, key = { it.expense.id }) { item -> ExpenseRow(item) { deleteTarget = item.expense } }
                item {
                    Text(state.status, color = Muted, fontSize = 11.sp, lineHeight = 17.sp)
                    Spacer(Modifier.height(5.dp))
                    Text("USD only · Local demo ledger", color = Muted.copy(alpha = 0.75f), fontSize = 10.sp)
                }
            }
        }
    }
    if (showAdd) ExpenseDialog(state.saving, { showAdd = false }) { amount, category, note, date -> onAdd(amount, category, note, date) { showAdd = false; tab = 0 } }
    if (showSettings) SettingsDialog(state, { showSettings = false }) { budget, endpoint -> onSettings(budget, endpoint) { showSettings = false } }
    deleteTarget?.let { expense ->
        AlertDialog(onDismissRequest = { deleteTarget = null }, title = { Text("Delete this expense?") }, text = { Text("${expense.note.ifBlank { expense.category.title }} · ${Money.format(expense.amountCents)}\nThe deletion will be saved locally and sent on your next sync.") }, confirmButton = { TextButton(onClick = { onDelete(expense.id); deleteTarget = null }, modifier = Modifier.testTag("confirmDelete")) { Text("Delete", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Keep expense") } })
    }
    state.error?.let { message -> AlertDialog(onDismissRequest = onClearError, title = { Text("A quick heads-up") }, text = { Text(message) }, confirmButton = { TextButton(onClick = onClearError) { Text("OK") } }) }
}

@Composable private fun BudgetHero(state: LedgerUiState) {
    val remaining = state.budgetCents - state.spentCents
    Card(colors = CardDefaults.cardColors(containerColor = Forest), shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.fillMaxWidth().padding(24.dp)) {
            Text(if (remaining >= 0) "ROOM IN YOUR BUDGET" else "ABOVE YOUR BUDGET", color = Color(0xFFC0DBCA), fontSize = 10.sp, letterSpacing = 1.4.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(9.dp))
            Text(Money.format(kotlin.math.abs(remaining)), color = Color.White, fontSize = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-1).sp)
            Text(if (remaining >= 0) "left to spend this month" else "over your monthly limit", color = Color(0xFFC0DBCA), fontSize = 12.sp)
            Spacer(Modifier.height(22.dp))
            LinearProgressIndicator(progress = { (state.spentCents.toFloat() / state.budgetCents).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(6.dp).clip(CircleShape), color = Color(0xFFBCE0A7), trackColor = Color(0xFF3C6855))
            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Column { Text("SPENT", color = Color(0xFFC0DBCA), fontSize = 9.sp, letterSpacing = 1.sp); Text(Money.format(state.spentCents), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
                Column(horizontalAlignment = Alignment.End) { Text("MONTHLY LIMIT", color = Color(0xFFC0DBCA), fontSize = 9.sp, letterSpacing = 1.sp); Text(Money.format(state.budgetCents), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
            }
            Spacer(Modifier.height(13.dp))
            Text("On this device · through ${state.asOf.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))}", color = Color(0xFFB7D1C1), fontSize = 10.sp)
        }
    }
}

@Composable private fun CategoryCard(state: LedgerUiState) {
    val totals = state.reportedExpenses.groupBy { it.expense.category }.map { (category, rows) -> category to rows.sumOf { it.expense.amountCents } }.sortedByDescending { it.second }
    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (totals.isEmpty()) Text("Your categories will appear as you add expenses.", color = Muted, fontSize = 13.sp)
            totals.forEach { (category, cents) ->
                Column {
                    Row { Text(category.title, Modifier.weight(1f), fontSize = 12.sp, fontWeight = FontWeight.Medium); Text(Money.format(cents), fontSize = 12.sp, color = Ink) }
                    Spacer(Modifier.height(6.dp))
                    LinearProgressIndicator(progress = { if (state.spentCents == 0L) 0f else cents.toFloat() / state.spentCents }, modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape), color = Green, trackColor = Paper)
                }
            }
        }
    }
}

@Composable private fun ServerInsight(dashboard: Dashboard, pending: Boolean) {
    Card(shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = SoftGreen)) {
        Column(Modifier.padding(18.dp)) {
            Text("A LOOK AT YOUR PACE", color = Green, fontSize = 10.sp, letterSpacing = 1.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(7.dp))
            Text("${Money.format(dashboard.summary.projectedCents)} at month end", color = Forest, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
            Text("Simple spending-pace estimate, based on completed reporting days.", color = Muted, fontSize = 11.sp, lineHeight = 16.sp)
            Text("Daily room: ${Money.format(dashboard.summary.dailyAllowanceCents)}", color = Forest, fontSize = 12.sp)
            Spacer(Modifier.height(8.dp))
            Text("Cached server analytics · through ${dashboard.asOf}${if (pending) " · excludes pending changes" else ""}\nHaskell budget engine · Scala analytics", color = Muted, fontSize = 10.sp, lineHeight = 15.sp)
        }
    }
}

@Composable private fun SectionLabel(title: String, trailing: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { Text(title, Modifier.weight(1f), fontSize = 18.sp, fontWeight = FontWeight.SemiBold); Text(trailing, fontSize = 11.sp, color = Muted) }
}

@Composable private fun EmptyExpenses(onAdd: () -> Unit) {
    Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("A fresh page.", fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Forest)
            Spacer(Modifier.height(8.dp)); Text("Start with a coffee, a commute, or anything in between. Expenses stay available offline.", color = Muted, fontSize = 13.sp, lineHeight = 20.sp)
            TextButton(onClick = onAdd) { Text("Add your first expense") }
        }
    }
}

@Composable private fun ExpenseRow(item: LocalExpense, onDelete: () -> Unit) {
    val expense = item.expense
    Card(shape = RoundedCornerShape(18.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 10.dp, bottom = 10.dp, end = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(39.dp).clip(RoundedCornerShape(13.dp)).background(SoftGreen), contentAlignment = Alignment.Center) { Text(expense.category.symbol, color = Green, fontWeight = FontWeight.Bold) }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(expense.note.ifBlank { expense.category.title }, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium, fontSize = 13.sp)
                Text("${expense.category.title} · ${expense.date.format(DateTimeFormatter.ofPattern("MMM d", Locale.US))}${if (item.pending) " · pending" else ""}", color = Muted, fontSize = 10.sp)
            }
            Text(Money.format(expense.amountCents), fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            TextButton(onClick = onDelete, contentPadding = PaddingValues(8.dp), modifier = Modifier.semantics { contentDescription = "Delete ${expense.note.ifBlank { expense.category.title }}" }.testTag("delete-${expense.id}")) { Text("×", color = Muted, fontSize = 22.sp) }
        }
    }
}

@Composable private fun ExpenseDialog(saving: Boolean, onDismiss: () -> Unit, onSave: (String, Category, String, String) -> Unit) {
    var amount by rememberSaveable { mutableStateOf("") }; var note by rememberSaveable { mutableStateOf("") }
    var date by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }; var category by rememberSaveable { mutableStateOf(Category.FOOD) }
    var menu by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = { if (!saving) onDismiss() }, title = { Text("A new expense", fontWeight = FontWeight.SemiBold) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Saved on your device first. Sync when you are ready.", color = Muted, fontSize = 12.sp)
            OutlinedTextField(value = amount, onValueChange = { amount = it }, label = { Text("Amount (USD)") }, placeholder = { Text("0.00") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), singleLine = true, modifier = Modifier.fillMaxWidth().testTag("amountInput"))
            Box {
                OutlinedButton(onClick = { menu = true }, modifier = Modifier.fillMaxWidth().testTag("categoryInput")) { Text("Category: ${category.title}") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) { Category.entries.forEach { option -> DropdownMenuItem(text = { Text(option.title) }, onClick = { category = option; menu = false }) } }
            }
            OutlinedTextField(value = note, onValueChange = { note = it }, label = { Text("Note (optional)") }, supportingText = { Text("Up to 140 characters") }, modifier = Modifier.fillMaxWidth().testTag("noteInput"))
            OutlinedTextField(value = date, onValueChange = { date = it }, label = { Text("Date · YYYY-MM-DD") }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("dateInput"))
        }
    }, confirmButton = { Button(onClick = { onSave(amount, category, note, date) }, enabled = !saving, modifier = Modifier.testTag("saveExpense")) { Text(if (saving) "Saving…" else "Save expense") } }, dismissButton = { TextButton(onClick = onDismiss, enabled = !saving) { Text("Cancel") } })
}

@Composable private fun SettingsDialog(state: LedgerUiState, onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var budget by rememberSaveable { mutableStateOf(Money.input(state.budgetCents)) }
    var endpoint by rememberSaveable { mutableStateOf(state.endpoint) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Make it yours") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(value = budget, onValueChange = { budget = it }, label = { Text("Monthly budget (USD)") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth().testTag("budgetInput"))
            Text("Budget edits are saved offline and queued for your next sync.", color = Muted, fontSize = 12.sp)
            HorizontalDivider()
            Text("Development server", fontWeight = FontWeight.SemiBold)
            OutlinedTextField(value = endpoint, onValueChange = { endpoint = it }, label = { Text("Server URL") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth().testTag("endpointInput"))
            Text("Use 10.0.2.2 for the emulator or your computer's LAN address on a phone. First-time setup preserves offline changes. After a successful server sync, send pending changes before switching; synced cache is cleared.", color = Muted, fontSize = 11.sp, lineHeight = 17.sp)
            Text("One USD ledger · no bank connection", color = Green, fontSize = 11.sp)
        }
    }, confirmButton = { Button(onClick = { onSave(budget, endpoint) }, enabled = !state.syncing && !state.saving, modifier = Modifier.testTag("saveSettings")) { Text("Save settings") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}
